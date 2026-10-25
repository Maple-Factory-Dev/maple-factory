// The factory: tasks moving through planning, approval, building, review and merge, and the agent
// sessions doing the work. It lives in OrgHub (one per org), so every change here is serialized.
//
// A task's sessions all run in one worktree on one machine, branch `agent/<id>`: the planner makes
// it, the builder and reviewer reopen it. Agents report only through the `maple` MCP tools
// (tools.ts); a session that ends without reporting is classified by its end's cause (`ended`).

import type { Env } from "../env.ts";
import type {
  ChangeRequest, ClientMessage, Evidence, Finding, Hand, Machine, Member, Mockup, ReviewCheck, Role, RunnerMessage, ServerToClient,
  ServerToRunner, SessionEnd, Task,
} from "../wire.ts";
import { audit, machineHub } from "../util.ts";
import { Store, type TaskSession } from "./store.ts";
import { builderPrompt, plannerPrompt, reviewerPrompt } from "./prompts.ts";
import { allowed, toolsFor } from "./tools.ts";
import { assess, validPolicy } from "./policy.ts";
import type { Intake } from "./intake.ts";
import { checks, closePullRequest, createPullRequest, GitHubError, githubApp, mergePullRequest, PERMISSIONS, repoToken, rerunFailed } from "../github.ts";

const MAX_REVIEW_ROUNDS = 5;
/// Restarts after ends nobody chose (sleep, lost tmux, an update) before a person is asked.
/** How old a session must be before `reap` takes it for a leftover rather than one still starting. */
const REAP_AFTER_MS = 30_000;
const MAX_RESTARTS = 2;
/// How long a session that reported its last word gets to wrap up before it's closed.
const CLOSE_AFTER_MS = 8_000;
const MAX_EVENTS = 200;
const COLS = 160;
const ROWS = 48;

type Ctx = { member: Member };
type Reply = { result?: { summary: string; data?: unknown }; error?: string };
type Hooks = {
  broadcast(message: ServerToClient): void;
  machines(): Promise<Machine[]>;
  /** Tell the apps a machine's settings changed. */
  machineChanged(id: string): Promise<void>;
  waitUntil(p: Promise<unknown>): void;
};

export class FactoryError extends Error {}

const now = () => Date.now();
const branchName = (task: Task) => task.id.toLowerCase();
const fail = (message: string): never => {
  throw new FactoryError(message);
};

export class Engine {
  constructor(private env: Env, private store: Store, private hooks: Hooks, private intake: Intake) {}

  // ---------------------------------------------------------------------------
  // Apps

  /** A command from an app. Throws FactoryError with a message for the person. */
  async command(msg: ClientMessage, { member }: Ctx): Promise<void> {
    const who = member.login;
    switch (msg.type) {
      case "goal.save": {
        const goal = { ...msg.goal, prefix: msg.goal.prefix.trim().toUpperCase() };
        if (!/^[A-Z][A-Z0-9]{0,5}$/.test(goal.prefix)) fail("A goal's prefix is 1–6 letters or digits, starting with a letter.");
        if (!goal.name.trim()) fail("A goal needs a name.");
        if (!goal.id) goal.id = crypto.randomUUID();
        if (this.store.goals().some((g) => g.prefix === goal.prefix && g.id !== goal.id)) fail(`Another goal already uses ${goal.prefix}.`);
        this.store.saveGoal(goal);
        this.hooks.broadcast({ type: "goal.updated", goal });
        return;
      }
      case "policy.save": {
        if (member.role !== "admin") fail("Only admins can change the risk policy.");
        const problem = validPolicy(msg.policy);
        if (problem) fail(problem);
        this.store.savePolicy(msg.policy);
        await audit(this.env, who, "policy.saved", null, msg.policy);
        return this.policyChanged();
      }
      case "goal.acceptRisk": {
        const goal = this.store.goal(msg.goal) ?? fail("That goal isn't there any more.");
        if (member.role !== "admin" && goal.lead !== who) fail(`Only admins or ${goal.lead}, its lead, can accept risk for ${goal.name}.`);
        const rest = this.store.acceptances().filter((a) => a.goal !== goal.id);
        this.store.saveAcceptances(msg.upTo ? [...rest, { goal: goal.id, upTo: msg.upTo, by: who, at: now(), note: msg.note ?? null }] : rest);
        await audit(this.env, who, msg.upTo ? "risk.accepted" : "risk.withdrawn", goal.id, { upTo: msg.upTo, note: msg.note });
        return this.policyChanged();
      }
      case "machine.settings": {
        const machine = (await this.hooks.machines()).find((m) => m.id === msg.machine) ?? fail("That machine isn't there any more.");
        if (machine.owner !== who && member.role !== "admin") fail(`Only ${machine.owner} can change ${machine.name}'s settings.`);
        const s = msg.settings;
        if (s.capacity != null && (s.capacity < 0 || s.capacity > 16)) fail("A machine takes 0 to 16 sessions.");
        if (s.teamSlots > (s.capacity ?? this.capacity(machine))) fail("It can't lend more slots than it has.");
        const pausing = s.paused && !this.store.settings(machine.id).paused;
        this.store.saveSettings(machine.id, { ...s, loadCap: Math.min(1, Math.max(0.1, s.loadCap)) });
        await audit(this.env, who, "machine.settings", machine.id, s);
        if (pausing && msg.handOff) {
          // Teammates' tasks shouldn't wait out the owner's pause: their work goes to other machines.
          for (const session of this.store.liveSessions().filter((x) => x.machine === machine.id && x.kind === "team" && x.role !== "reviewer")) {
            const task = this.store.task(session.task);
            if (!task || task.worker?.session !== session.id) continue;
            this.event(task, who, `paused ${machine.name} and handed it off`);
            if (!(await this.handOff(task, who))) {
              this.relocate(task, who, machine.name, null);
            }
          }
        }
        await this.hooks.machineChanged(machine.id);
        await this.pump();
        return;
      }
      case "intake.attach": {
        const request = this.intake.get(msg.id) ?? fail("That request isn't there any more.");
        const task = this.store.task(msg.task) ?? fail("That task isn't there any more.");
        for (const t of request.tickets) if (!task.tickets.some((x) => x.key === t.key)) task.tickets.push(t);
        task.comments.push({ id: crypto.randomUUID(), author: request.requester, text: request.thread.filter((m) => !m.bot).map((m) => m.text).join("\n\n"), at: now(), anchor: null, via: sourceTitle(request) });
        this.event(task, who, `added ${request.requester}'s request (${request.id}) to it`);
        this.save(task);
        this.intake.accepted(request, task, "attached", who);
        return;
      }
      case "intake.ask": {
        const request = this.intake.get(msg.id) ?? fail("That request isn't there any more.");
        this.intake.ask(request, msg.text.trim() || fail("Say what to ask."));
        return;
      }
      case "intake.decline": {
        const request = this.intake.get(msg.id) ?? fail("That request isn't there any more.");
        this.intake.decline(request, who, msg.note ?? null);
        return;
      }
      case "task.create": {
        const goal = this.store.goal(msg.goal) ?? fail("That goal isn't there any more.");
        if (!msg.title.trim()) fail("A task needs a title.");
        const request = msg.intake ? this.intake.get(msg.intake) : null;
        const t = now();
        const task: Task = {
          id: this.store.nextId(goal.prefix),
          goal: goal.id,
          title: msg.title.trim(),
          state: "drafting",
          owner: who,
          brief: msg.brief,
          createdAt: t,
          updatedAt: t,
          plan: [],
          planVersion: 0,
          doneWhen: [],
          approvals: [],
          approvalsNeeded: 1,
          reviews: [],
          reviewsNeeded: 1,
          comments: [],
          changes: [],
          events: [{ who, text: "created it", at: t }],
          mockups: [],
          tickets: msg.tickets,
          shareable: msg.shareable,
          agent: msg.agent || "claude",
          intake: request?.id ?? null,
        };
        if (request) {
          for (const t of request.tickets) if (!task.tickets.some((x) => x.key === t.key)) task.tickets.push(t);
          for (const m of request.thread.filter((m) => !m.bot)) task.comments.push({ id: crypto.randomUUID(), author: m.author, text: m.text, at: m.at, anchor: null, via: sourceTitle(request) });
        }
        this.save(task);
        await audit(this.env, who, "task.created", task.id, { title: task.title });
        if (msg.plan) await this.startPlanning(task, who);
        if (request) this.intake.accepted(request, this.store.task(task.id) ?? task, "created", who);
        return;
      }
    }

    const task = this.store.task(msg.type === "subscribe" ? "" : (msg as { id: string }).id) ?? fail("That task isn't there any more.");
    switch (msg.type) {
      case "task.edit": {
        if (task.state !== "drafting" && msg.brief != null && msg.brief !== task.brief) fail("The brief can only change while it's a draft; steer it instead.");
        if (msg.title != null && msg.title.trim()) task.title = msg.title.trim();
        if (msg.brief != null) task.brief = msg.brief;
        if (msg.shareable != null) task.shareable = msg.shareable;
        this.event(task, who, "edited it");
        this.save(task);
        await this.pump();
        return;
      }
      case "task.plan":
        if (task.state !== "drafting") fail("It's already past drafting.");
        return this.startPlanning(task, who);
      case "task.comment": {
        const text = msg.text.trim() || fail("Say something.");
        task.comments.push({ id: crypto.randomUUID(), author: who, text, at: now(), anchor: msg.anchor ?? null });
        this.save(task);
        return;
      }
      case "task.steer": {
        const text = msg.text.trim() || fail("Say what to change.");
        if (!["planning", "awaitingApproval", "building", "reviewing"].includes(task.state)) fail("There's nothing working on it to steer.");
        if (task.state === "reviewing" && this.store.private(task.id).merging) fail("It's merging now.");
        const change: ChangeRequest = { id: `C${task.changes.length + 1}`, author: who, text, at: now(), anchor: msg.anchor ?? null, status: "queued", timing: null };
        task.changes.push(change);
        this.event(task, who, `asked for a change: ${text}`);
        if (task.state === "awaitingApproval") {
          // The plan isn't approved yet: the planner revises it.
          task.approvals = [];
          this.save(task);
          return this.startPlanning(task, who, true);
        }
        if (task.state === "reviewing") {
          // A person's request for changes: the builder takes it, and review starts over on what it pushes.
          await this.closeWorker(task, "cancelled");
          if (task.autoReview?.rounds.at(-1)?.verdict === "inProgress") task.autoReview.rounds.pop();
          task.reviews = [];
          task.state = "building";
          this.save(task);
          await this.pump();
          return;
        }
        if (task.worker && (await this.type(task, `Change request ${change.id} from ${who}: ${text}\nApply it, then report it with \`progress\` (applied: ["${change.id}"]).`))) {
          change.status = "applying";
        }
        this.save(task);
        return;
      }
      case "task.approvePlan": {
        if (task.state !== "awaitingApproval") fail("There's no plan waiting for approval.");
        if (task.approvals.includes(who)) fail("You've already approved it.");
        task.approvals.push(who);
        for (const m of task.mockups) if (m.status === "proposed") m.status = "approved";
        this.event(task, who, "approved the plan");
        if (task.approvals.length >= task.approvalsNeeded) {
          task.state = "building";
          task.waiting = null;
          this.event(task, "factory", "queued it for building");
        }
        this.save(task);
        await this.pump();
        return;
      }
      case "task.answer": {
        const q = task.question ?? fail("There's no question waiting.");
        task.question = null;
        task.comments.push({ id: crypto.randomUUID(), author: who, text: msg.text, at: now(), anchor: `Q: ${q.text}`, via: null });
        this.event(task, who, `answered: ${msg.text}`);
        this.save(task);
        if (!(await this.type(task, `${who} answered your question ("${q.text}"): ${msg.text}`))) await this.pump();
        return;
      }
      case "task.resolveHand": {
        const hand = task.hand ?? fail("Nobody's asking for a hand.");
        const option = msg.option ? hand.options.find((o) => o.title === msg.option) : undefined;
        task.hand = null;
        const decision = [option ? `Go with: ${option.title} — ${option.detail}` : null, msg.note.trim() || null].filter(Boolean).join("\n");
        if (decision) task.comments.push({ id: crypto.randomUUID(), author: who, text: decision, at: now(), anchor: `Hand: ${hand.summary}`, via: null });
        this.event(task, who, option ? `picked "${option.title}"` : "resolved the hand raise");
        if (hand.reason === "reviewLoop" && task.autoReview) task.autoReview.maxRounds += 2;
        this.store.savePrivate(task.id, { ...this.store.private(task.id), restarts: 0 });
        this.save(task);
        if (!(await this.type(task, `${who} answered your raised hand: ${decision || "carry on."}`))) await this.pump();
        return;
      }
      case "task.approveChanges": {
        if (task.state !== "reviewing" || task.autoReview?.rounds.at(-1)?.verdict !== "passed") fail("It isn't ready for review yet.");
        if (task.reviews.includes(who)) fail("You've already approved it.");
        task.reviews.push(who);
        this.event(task, who, "approved the changes");
        this.save(task);
        await this.autoMerge(task);
        return;
      }
      case "task.merge": {
        if (task.state !== "reviewing" || !task.pr) fail("There's nothing to merge.");
        if (task.autoReview?.rounds.at(-1)?.verdict !== "passed") fail("It hasn't passed automatic review.");
        if (task.reviews.length < task.reviewsNeeded) fail("It needs its approvals first.");
        if (task.pr!.checks.some((c) => c.status === "failed")) fail("CI is failing; run the failed checks again or fix them first.");
        if (task.pr!.checks.some((c) => c.status !== "passed")) fail("CI is still running.");
        await this.startMerge(task, who);
        return;
      }
      case "task.cancel": {
        if (task.state === "merged" || task.state === "cancelled") fail("It's already finished.");
        await this.closeWorker(task, "cancelled");
        task.state = "cancelled";
        // Nothing's reviewing it or going to merge it now.
        if (task.pr && (task.pr.state === "open" || task.pr.state === "draft")) {
          task.pr.state = "closed";
          const app = githubApp(this.env);
          const gh = this.store.private(task.id).gh;
          if (app && gh && task.pr.url) {
            this.hooks.waitUntil(closePullRequest(app, gh.owner, gh.repo, task.pr.number, `${who} cancelled ${task.id} in Maple Factory.`).catch(() => {}));
          }
        }
        if (task.autoReview?.rounds.at(-1)?.verdict === "inProgress") task.autoReview.rounds.pop();
        task.waiting = null;
        task.question = null;
        task.hand = null;
        this.event(task, who, "cancelled it");
        this.save(task);
        await audit(this.env, who, "task.cancelled", task.id);
        await this.pump();
        return;
      }
      case "task.retry": {
        if (task.worker) fail("It's already running.");
        if (task.state === "cancelled") {
          task.state = task.plan.length ? "building" : "drafting";
        }
        task.hand = null;
        task.waiting = null;
        this.store.savePrivate(task.id, { ...this.store.private(task.id), restarts: 0 });
        this.event(task, who, "retried it");
        this.save(task);
        await this.pump();
        return;
      }
      case "task.move": {
        if (task.state === "merged" || task.state === "cancelled" || task.state === "drafting") fail("There's nothing running to move.");
        if (!task.machine) fail("It hasn't started on a machine yet.");
        if (this.store.private(task.id).handingOff) fail("It's already being handed off.");
        const from = (await this.hooks.machines()).find((m) => m.id === task.machine);
        const stuck = !from || !from.online || this.store.settings(from.id).paused || !task.worker;
        if (!stuck) fail(`It's running on ${from!.name}; it moves when that machine is offline or paused, or once it stops.`);
        await audit(this.env, who, "task.moved", task.id, { from: from?.id ?? task.machine });
        // A machine that's still there pushes the work it has first, so nothing stays behind on it.
        if (from?.online && (await this.handOff(task, who))) return;
        this.relocate(task, who, from?.name ?? task.machine ?? "its machine", null);
        await this.pump();
        return;
      }
      case "task.rerunChecks": {
        const app = githubApp(this.env);
        const priv = this.store.private(task.id);
        if (!app || !priv.gh || !task.pr) fail("Its checks aren't on GitHub.");
        const failed = (priv.checks ?? []).filter((c) => c.status === "failed");
        if (!failed.length) fail("No checks have failed.");
        const asked = await rerunFailed(app!, priv.gh!.owner, priv.gh!.repo, failed).catch((e) => fail((e as Error).message));
        for (const c of task.pr!.checks) if (c.status === "failed") c.status = "queued";
        this.event(task, who, `ran ${failed.map((c) => c.name).join(", ")} again`);
        this.save(task);
        await audit(this.env, who, "task.rerunChecks", task.id, { asked });
        return;
      }
      case "task.split": {
        if (task.state !== "awaitingApproval" && task.state !== "building") fail("Only a planned task that isn't finished can be split.");
        const steps = task.plan;
        const parts = Math.max(2, Math.min(msg.parts, steps.length));
        if (steps.length < 2) fail("It needs at least two steps to split.");
        // Building keeps everything up to the step it's on; otherwise it keeps an even share.
        const reached = steps.reduce((last, s, i) => (s.progress ? i : last), -1);
        const keep = Math.min(steps.length - parts + 1, Math.max(task.state === "building" ? reached + 1 : Math.ceil(steps.length / parts), 1));
        const rest = steps.slice(keep);
        const per = Math.ceil(rest.length / (parts - 1));
        const created: Task[] = [];
        for (let i = 0; i < rest.length; i += per) {
          const chunk = rest.slice(i, i + per);
          const t = now();
          const part: Task = {
            ...structuredClone(task),
            id: this.store.nextId(this.store.goal(task.goal)?.prefix ?? task.id.split("-")[0]),
            title: chunk.length > 1 ? `${chunk[0].text} (+${chunk.length - 1} more)` : chunk[0].text,
            state: "drafting",
            brief: `Split from ${task.id} (${task.title}) to stay inside the PR budget. This task does these steps of its plan:\n\n${chunk.map((s) => `- ${s.text}${s.file ? ` (${s.file})` : ""}`).join("\n")}\n\n## ${task.id}'s brief\n\n${task.brief}`,
            createdAt: t,
            updatedAt: t,
            plan: [],
            planVersion: 0,
            doneWhen: [],
            approvals: [],
            reviews: [],
            comments: [],
            changes: [],
            events: [{ who, text: `split it off ${task.id}`, at: t }],
            mockups: [],
            question: null,
            hand: null,
            worker: null,
            liveLog: null,
            waiting: null,
            pr: null,
            diff: null,
            footprint: null,
            risk: null,
            autoReview: null,
            branch: null,
            machine: null,
            intake: null,
            splitFrom: task.id,
          };
          this.save(part);
          created.push(part);
        }
        const moved = created.map((p) => p.id).join(", ");
        task.plan = steps.slice(0, keep);
        this.event(task, who, `split it into ${created.length + 1} tasks: ${[task.id, ...created.map((p) => p.id)].join(", ")}`);
        await audit(this.env, who, "task.split", task.id, { into: created.map((p) => p.id) });
        if (task.state === "awaitingApproval") {
          // The plan isn't approved: the planner rescopes it (and its checks) to what's left.
          task.changes.push({ id: `C${task.changes.length + 1}`, author: who, text: `Split: keep only the first ${keep} step${keep === 1 ? "" : "s"}; the rest moved to ${moved}. Rescope the plan, its checks and mockups to match.`, at: now(), anchor: null, status: "queued", timing: null });
          task.approvals = [];
          this.save(task);
          await this.startPlanning(task, who, true);
        } else {
          const change: ChangeRequest = { id: `C${task.changes.length + 1}`, author: who, text: `Stop after step ${keep}: steps ${keep + 1}–${steps.length} moved to ${moved}. Leave them out of this change.`, at: now(), anchor: null, status: "queued", timing: null };
          task.changes.push(change);
          if (task.worker && (await this.type(task, `Change request ${change.id} from ${who}: ${change.text}\nApply it, then report it with \`progress\` (applied: ["${change.id}"]).`))) change.status = "applying";
          this.save(task);
        }
        for (const part of created) await this.startPlanning(part, who);
        return;
      }
      case "task.checkedIt": {
        const item = task.doneWhen[msg.item] ?? fail("There's no such Done when item.");
        item.status = "proven";
        item.evidence = { kind: item.proof, summary: msg.note?.trim() || `${who} checked it by hand.`, output: [], by: who, at: now() };
        this.event(task, who, `checked "${item.text}"`);
        this.save(task);
        return;
      }
      case "task.mockupChange": {
        const mockup = task.mockups.find((m) => m.id === msg.mockup) ?? fail("That mockup isn't there any more.");
        mockup.status = "changesRequested";
        task.changes.push({ id: `C${task.changes.length + 1}`, author: who, text: msg.text, at: now(), anchor: `Mockup: ${mockup.title}`, status: "queued", timing: null });
        this.event(task, who, `asked for a change to the "${mockup.title}" mockup`);
        if (task.state === "awaitingApproval") {
          task.approvals = [];
          this.save(task);
          return this.startPlanning(task, who, true);
        }
        this.save(task);
        return;
      }
    }
  }

  private async startPlanning(task: Task, who: string, revise = false) {
    task.state = "planning";
    task.waiting = null;
    this.event(task, who, revise ? "sent it back to the planner" : "sent it to planning");
    this.save(task);
    await this.pump();
  }

  // ---------------------------------------------------------------------------
  // Dispatch

  /** Starts a session for every task that should have one and doesn't, where there's room. */
  private pumping: Promise<void> | null = null;
  private pumpAgain = false;

  /** One pump at a time (they await the machines, so two could start the same task twice); a pump
   *  asked for while one runs happens once it's done. */
  async pump(): Promise<void> {
    if (this.pumping) {
      this.pumpAgain = true;
      return this.pumping;
    }
    this.pumping = (async () => {
      do {
        this.pumpAgain = false;
        await this.pumpOnce();
      } while (this.pumpAgain);
    })().finally(() => (this.pumping = null));
    return this.pumping;
  }

  private async pumpOnce(): Promise<void> {
    const machines = await this.hooks.machines();
    for (const listed of this.store.tasks().reverse()) {
      // Read it again: what an earlier dispatch awaited may have changed it (a cancel, a move).
      const task = this.store.task(listed.id);
      if (!task) continue;
      const role = this.roleFor(task);
      if (!role || task.worker || task.hand || task.question) continue;
      const waiting = await this.dispatch(task, role, machines);
      if (waiting !== (task.waiting ?? null)) {
        task.waiting = waiting;
        this.save(task);
      }
    }
  }

  /** Whether any task is waiting for a machine. */
  waiting(): boolean {
    return this.store.tasks().some((t) => t.waiting && !t.worker);
  }

  /** The session a task needs now, if any. */
  private roleFor(task: Task): Role | null {
    switch (task.state) {
      case "planning": return "planner";
      case "building": return this.store.private(task.id).finishing ? null : "builder";
      case "reviewing": return task.autoReview?.rounds.at(-1)?.verdict === "inProgress" ? "reviewer" : null;
      default: return null;
    }
  }

  /** Starts `role` for `task`, or says why it can't yet. */
  private async dispatch(task: Task, role: Role, machines: Machine[]): Promise<string | null> {
    const goal = this.store.goal(task.goal);
    if (!goal) return "Its goal is gone.";
    if (!goal.folder && !goal.repo) return `The goal ${goal.name} doesn't say where its code is: set a repo or folder.`;
    const priv = this.store.private(task.id);
    const live = this.store.liveSessions();
    const busy = (m: string, kind?: string) => live.filter((s) => s.machine === m && (!kind || s.kind === kind)).length;

    let machine: Machine | undefined;
    let kind: TaskSession["kind"] = "personal";
    if (task.machine && priv.worktree) {
      // Its worktree is on one machine: the rest of its sessions run there.
      machine = machines.find((m) => m.id === task.machine);
      if (!machine) return `${task.machine} was removed; move it to start over elsewhere.`;
      if (!machine.online) return `Waiting for ${machine.name} to come back online.`;
      if (this.store.settings(machine.id).paused) return `${machine.name} is paused.`;
      const capped = this.overCap(machine, task.agent);
      if (capped) return capped;
      kind = machine.owner === task.owner ? "personal" : "team";
    } else {
      const usable = machines.filter((m) => m.online && !this.store.settings(m.id).paused && this.hasAgent(m, task.agent) && !this.overCap(m, task.agent));
      const own = usable.filter((m) => m.owner === task.owner && busy(m.id) < this.capacity(m));
      machine = own.sort((a, b) => busy(a.id) - busy(b.id))[0];
      if (!machine && task.shareable) {
        const lent = usable.filter((m) => {
          const s = this.store.settings(m.id);
          const load = m.health ? m.health.load1 / Math.max(1, m.health.cores) : 0;
          const lendable = s.lendIdle ? this.capacity(m) : s.teamSlots;
          return m.owner !== task.owner && busy(m.id, "team") < lendable && busy(m.id) < this.capacity(m) && load < s.loadCap;
        });
        machine = lent.sort((a, b) => busy(a.id) - busy(b.id))[0];
        kind = "team";
      }
      if (!machine) {
        const mine = machines.filter((m) => m.owner === task.owner);
        if (!mine.length) return task.shareable ? "Waiting for a free team slot (you have no machines)." : "Waiting for one of your machines: add one under Machines.";
        const online = mine.filter((m) => m.online);
        if (!online.length) return task.shareable ? "Your machines are offline; waiting for them or a team slot." : "Waiting for one of your machines to come online.";
        const running = online.filter((m) => !this.store.settings(m.id).paused);
        if (!running.length) {
          const names = online.map((m) => m.name).join(", ");
          return task.shareable ? `${names} ${online.length === 1 ? "is" : "are"} paused; waiting for a team slot.` : `${names} ${online.length === 1 ? "is" : "are"} paused.`;
        }
        if (!running.some((m) => this.hasAgent(m, task.agent))) return `None of your online machines has ${task.agent} installed.`;
        const capped = running.map((m) => this.overCap(m, task.agent)).find(Boolean);
        if (capped && !running.some((m) => this.hasAgent(m, task.agent) && !this.overCap(m, task.agent))) return capped;
        return task.shareable ? "Waiting for a free slot on your machines or the team's." : "Waiting for a free slot on your machines.";
      }
    }

    const id = crypto.randomUUID();
    const resumed = priv.movedFrom
      ? { reason: `This task was moved here from ${priv.movedFrom.machine}${priv.movedFrom.commit ? `; its work so far is on the branch, up to ${priv.movedFrom.commit.slice(0, 7)} (any "WIP" commit is unfinished)` : ""}.` }
      : priv.restarts > 0 ? { reason: "Your last session ended before you finished." } : null;
    const prompt = role === "planner" ? plannerPrompt(task, goal) : role === "builder" ? builderPrompt(task, goal, resumed) : reviewerPrompt(task, goal, priv.base ?? goal.base ?? "main");
    const existing = Boolean(priv.worktree && task.machine === machine.id);
    const command: ServerToRunner = {
      type: "session.open",
      id,
      agent: task.agent,
      cwd: existing ? priv.worktree! : (goal.folder ?? "~"),
      cols: COLS,
      rows: ROWS,
      prompt,
      resume: false,
      taskId: task.id,
      worktree: { name: branchName(task), base: goal.base ?? null, existing },
      task: { id: task.id, repo: goal.repo ?? null },
      unattended: { mode: this.store.get("unattended") ?? "project", commands: [] },
      model: null,
    };
    if (!(await this.toRunner(machine.id, command))) return `Couldn't reach ${machine.name}.`;
    const now_ = this.store.task(task.id);
    if (!now_ || now_.worker || this.roleFor(now_) !== role) {
      // It was cancelled, moved or started elsewhere while the machine was opening this one.
      this.hooks.waitUntil(this.toRunner(machine.id, { type: "session.kill", id }, "factory"));
      return null;
    }
    Object.assign(task, now_);
    this.store.addSession({ id, task: task.id, role, machine: machine.id, agent: task.agent, started: now(), ended: null, cause: null, kind });
    if (priv.movedFrom) this.store.savePrivate(task.id, { ...this.store.private(task.id), movedFrom: null });
    task.worker = { role, agent: task.agent, machine: machine.id, session: id, startedAt: now() };
    task.machine = machine.id;
    task.branch = `agent/${branchName(task)}`;
    task.liveLog = role === "planner" ? "Reading the code…" : role === "builder" ? "Starting…" : "Reading the change…";
    this.event(task, role, `started on ${machine.name}${kind === "team" ? ` (a team slot from ${machine.owner})` : ""}`);
    this.save(task);
    return null;
  }

  /** Why a machine's usage cap stops new work for `agent` there, if it does. */
  private overCap(machine: Machine, agent: string): string | null {
    const s = this.store.settings(machine.id);
    const usage = machine.usage?.find((u) => u.agent === agent);
    if (!usage) return null;
    for (const w of usage.windows) {
      const cap = w.label === "5h" ? s.sessionCap : w.label === "7d" && !w.name ? s.weeklyCap : null;
      if (cap != null && w.usedPercent >= cap * 100) {
        const window = w.label === "5h" ? "5-hour session" : "week";
        return `${machine.name}'s ${agent} account has used ${Math.round(w.usedPercent)}% of its ${window} (the cap is ${Math.round(cap * 100)}%).`;
      }
    }
    return null;
  }

  private hasAgent(machine: Machine, agent: string) {
    // Before its first health report a machine's agents aren't known; let it try.
    // Health lists the agents it knows to look for; others (agents.toml) are assumed present.
    if (!["claude", "codex"].includes(agent)) return true;
    return !machine.health || machine.health.agents.some((a) => a.name === agent);
  }

  /** The factory sessions a machine takes now: its setting, else from its cores. */
  capacity(machine: Machine) {
    const set = this.store.settings(machine.id).capacity;
    if (set != null) return set;
    const cores = machine.health?.cores ?? 4;
    return Math.max(1, Math.min(4, Math.floor(cores / 4)));
  }

  // ---------------------------------------------------------------------------
  // Runners

  /** What a runner said that's about the factory. `mcp.request` gets an answer for the runner. */
  async fromRunner(machine: string, msg: RunnerMessage): Promise<Reply | null> {
    switch (msg.type) {
      case "mcp.request": return this.tool(msg.session, msg.tool, (msg.args ?? {}) as Record<string, unknown>);
      case "session.opened": {
        const s = msg.session.taskId ? this.store.session(msg.session.id) : null;
        if (!s) return null;
        const task = this.store.task(s.task);
        if (!task) return null;
        const priv = this.store.private(task.id);
        // The planner's session opens in the worktree it made.
        if (!priv.worktree || task.machine !== machine) this.store.savePrivate(task.id, { ...priv, worktree: msg.session.cwd });
        return null;
      }
      case "session.error": {
        const s = this.store.session(msg.id);
        if (!s) return null;
        this.store.endSession(msg.id, "error");
        const task = this.store.task(s.task);
        if (!task || task.worker?.session !== msg.id) return null;
        task.worker = null;
        task.liveLog = null;
        this.raise(task, s.role, "sessionEnded", `Its ${s.role} couldn't start on ${machine}: ${msg.message}`);
        this.save(task);
        return null;
      }
      case "session.activity": {
        const s = this.store.session(msg.id);
        const task = s && this.store.task(s.task);
        if (!task || task.worker?.session !== msg.id) return null;
        const line = msg.activity.state === "waiting" ? `Waiting: ${msg.activity.message ?? "a permission prompt"}` : (msg.activity.step ?? msg.activity.message);
        if (line && line !== task.liveLog) {
          task.liveLog = line;
          this.save(task, false);
        }
        return null;
      }
      case "session.ended": {
        await this.ended(msg.end);
        return null;
      }
      case "task.started": {
        const task = this.store.task(msg.taskId);
        if (!task) return null;
        this.store.savePrivate(task.id, { ...this.store.private(task.id), repoDir: msg.repoDir, base: msg.base });
        return null;
      }
      case "task.finished": return this.finished(msg), null;
      case "task.handed_off": return this.handedOff(machine, msg), null;
      case "task.diff": {
        const task = this.store.task(msg.taskId);
        if (!task || !msg.ok) return null;
        this.store.set(`patch:${task.id}`, msg.patch);
        task.diff = {
          added: msg.files.reduce((n, f) => n + f.added, 0),
          removed: msg.files.reduce((n, f) => n + f.removed, 0),
          files: msg.files.map((f) => f.path),
        };
        // Measured now, not estimated: the size can change its risk.
        this.applyPolicy(task);
        this.save(task, false);
        await this.autoMerge(task);
        return null;
      }
      case "task.merged": return this.merged(msg), null;
      case "task.token_request": {
        // A token for the task's repo, only for the machine it's on; without the app the runner
        // fetches and pushes with the machine's own credentials.
        const reply = (token: string | null, error: string | null, code: string | null) =>
          this.toRunner(machine, { type: "task.token", reqId: msg.reqId, token, error, code });
        const app = githubApp(this.env);
        if (!app) return await reply(null, "The factory has no GitHub App installed.", "not_installed"), null;
        const task = this.store.task(msg.taskId);
        const goal = task && this.store.goal(task.goal);
        if (!task || task.machine !== machine) return await reply(null, "That task isn't running on this machine.", "api"), null;
        if (goal?.repo && goal.repo.toLowerCase() !== `${msg.owner}/${msg.repo}`.toLowerCase()) return await reply(null, `${task.id} works on ${goal.repo}, not ${msg.owner}/${msg.repo}.`, "api"), null;
        try {
          const { token } = await repoToken(app, msg.owner, msg.repo, msg.purpose === "fetch" ? PERMISSIONS.fetch : PERMISSIONS.push);
          await reply(token, null, null);
        } catch (e) {
          await reply(null, (e as Error).message, e instanceof GitHubError ? e.code : "api");
        }
        return null;
      }
      default:
        return null;
    }
  }

  /** A session ended. The ones the factory closed are already marked; anything else is unplanned. */
  private async ended(end: SessionEnd) {
    const s = this.store.session(end.id);
    if (!s) return;
    const planned = s.ended != null;
    this.store.endSession(end.id, end.cause);
    const task = this.store.task(s.task);
    if (!task) return;
    if (task.worker?.session !== end.id) return this.cleanup(task);
    task.worker = null;
    task.liveLog = null;
    if (planned || task.state === "cancelled" || task.state === "merged") {
      this.save(task);
      await this.cleanup(task);
      return this.pump();
    }
    const priv = this.store.private(task.id);
    const where = s.machine;
    switch (end.cause) {
      case "machineSlept":
      case "tmuxLost":
      case "runnerUpdated":
      case "signaled":
      case "outOfMemory":
        if (priv.restarts < MAX_RESTARTS) {
          this.store.savePrivate(task.id, { ...priv, restarts: priv.restarts + 1 });
          this.event(task, "factory", `its ${s.role} ended (${describeCause(end)}); starting it again`);
          this.save(task);
          return this.pump();
        }
        this.raise(task, s.role, "sessionEnded", `Its ${s.role} on ${where} keeps ending (${describeCause(end)}).`);
        break;
      case "authExpired":
        this.raise(task, s.role, "sessionEnded", `${task.agent}'s login on ${where} expired. Sign in again there, then pick Retry.`);
        break;
      case "usageLimit":
        this.raise(task, s.role, "sessionEnded", `The ${task.agent} account on ${where} hit its usage limit. Retry when it resets, or move it.`);
        break;
      case "killed":
        this.raise(task, s.role, "sessionEnded", `${end.by ?? "Someone"} ended its ${s.role} session.`);
        break;
      default:
        this.raise(task, s.role, "sessionEnded", `Its ${s.role} exited before it reported back${end.code != null ? ` (code ${end.code})` : ""}.`);
    }
    this.save(task);
  }

  private finished(msg: Extract<RunnerMessage, { type: "task.finished" }>) {
    const task = this.store.task(msg.taskId);
    if (!task) return;
    const priv = this.store.private(task.id);
    this.store.savePrivate(task.id, { ...priv, finishing: false });
    if (!msg.ok) {
      this.raise(task, "builder", "needsInput", `Pushing failed: ${msg.message ?? "no reason given"}.`);
      this.save(task);
      return;
    }
    const goal = this.store.goal(task.goal);
    const base = msg.base ?? priv.base ?? goal?.base ?? "main";
    task.pr = task.pr
      ? { ...task.pr, head: msg.commit ?? null, state: "open" }
      : { number: Number(this.store.nextId("PR").split("-")[1]), url: null, state: "open", head: msg.commit ?? null, branch: msg.branch, base, checks: [] };
    this.closeWorker(task, "done");
    task.state = "reviewing";
    task.reviews = [];
    const review = task.autoReview ?? { maxRounds: MAX_REVIEW_ROUNDS, rounds: [], summary: "", ask: [], proofs: [], findings: [] };
    review.rounds.push({ number: review.rounds.length + 1, verdict: "inProgress", found: 0, at: now(), fix: null });
    task.autoReview = review;
    this.event(task, "builder", `pushed ${msg.commit?.slice(0, 7) ?? msg.branch}${msg.pushed === "fallback" ? " with the machine's credentials" : ""}`);
    this.save(task);
    if (task.machine && priv.worktree) this.hooks.waitUntil(this.toRunner(task.machine, { type: "task.diff", taskId: task.id, cwd: priv.worktree, base }));
    if (msg.pushed === "app" && msg.owner && msg.repo) this.hooks.waitUntil(this.openPull(task.id, msg.owner, msg.repo));
    this.hooks.waitUntil(this.pump());
  }

  // ---------------------------------------------------------------------------
  // GitHub: the pull request and its CI, when the app pushed the branch

  /** Opens the task's pull request on GitHub (or finds it, pushed again), then reads its CI. */
  private async openPull(id: string, owner: string, repo: string) {
    const app = githubApp(this.env);
    let task = this.store.task(id);
    if (!app || !task?.pr) return;
    try {
      if (!task.pr.url) {
        const pr = await createPullRequest(app, owner, repo, { title: `${task.id}: ${task.title}`, head: task.pr.branch, base: task.pr.base, body: pullBody(task) });
        task = this.store.task(id);
        if (!task?.pr) return;
        task.pr.number = pr.number;
        task.pr.url = pr.url;
        this.event(task, "factory", `opened pull request #${pr.number} on ${owner}/${repo}`);
      }
      this.store.savePrivate(task.id, { ...this.store.private(task.id), gh: { owner, repo } });
      this.save(task);
      await this.refreshChecks(task.id);
    } catch (e) {
      const t = this.store.task(id);
      if (!t) return;
      this.event(t, "factory", `couldn't open a pull request on ${owner}/${repo}: ${(e as Error).message}`);
      this.save(t);
    }
  }

  /** Reads the task's CI from GitHub; all passed may let it merge. */
  async refreshChecks(id: string) {
    const app = githubApp(this.env);
    const task = this.store.task(id);
    const gh = task && this.store.private(id).gh;
    if (!app || !task?.pr?.head || !gh) return;
    const found = await checks(app, gh.owner, gh.repo, task.pr.head).catch(() => null);
    const now_ = this.store.task(id);
    if (!found || !now_?.pr) return;
    const before = now_.pr.checks.map((c) => `${c.name}:${c.status}`).join();
    now_.pr.checks = found.map((c) => ({ name: c.name, status: c.status, duration: c.duration, required: true }));
    this.store.savePrivate(id, { ...this.store.private(id), checks: found });
    if (now_.pr.checks.map((c) => `${c.name}:${c.status}`).join() === before) return;
    const failed = found.filter((c) => c.status === "failed");
    if (failed.length) this.event(now_, "factory", `CI failed: ${failed.map((c) => c.name).join(", ")}`);
    else if (found.length && found.every((c) => c.status === "passed")) this.event(now_, "factory", "CI passed");
    this.save(now_);
    await this.autoMerge(now_);
  }

  /** A GitHub webhook about a repo's checks or pull requests: the tasks it's about read their CI again. */
  async fromGitHub(event: { owner: string; repo: string; sha?: string | null; number?: number | null; merged?: boolean; closed?: boolean }) {
    const repo = `${event.owner}/${event.repo}`.toLowerCase();
    for (const task of this.store.tasks()) {
      const gh = this.store.private(task.id).gh;
      if (!gh || `${gh.owner}/${gh.repo}`.toLowerCase() !== repo || !task.pr) continue;
      if (!(event.sha && task.pr.head === event.sha) && !(event.number && task.pr.number === event.number)) continue;
      if (event.closed && task.state !== "merged" && task.state !== "cancelled") {
        if (event.merged) this.merged({ type: "task.merged", taskId: task.id, ok: true, commit: null, message: null });
        else {
          task.pr.state = "closed";
          this.event(task, "factory", `pull request #${task.pr.number} was closed on GitHub`);
          this.save(task);
        }
        continue;
      }
      await this.refreshChecks(task.id);
    }
  }

  private merged(msg: Extract<RunnerMessage, { type: "task.merged" }>) {
    const task = this.store.task(msg.taskId);
    if (!task || !task.pr) return;
    task.liveLog = null;
    this.store.savePrivate(task.id, { ...this.store.private(task.id), merging: false });
    if (!msg.ok) {
      this.event(task, "factory", `couldn't merge: ${msg.message ?? "no reason given"}`);
      this.hooks.broadcast({ type: "toast", text: `${task.id} didn't merge: ${msg.message ?? "no reason given"}`, taskId: task.id });
      this.save(task);
      return;
    }
    task.state = "merged";
    task.pr.state = "merged";
    this.event(task, "factory", `merged into ${task.pr.base} (${msg.commit?.slice(0, 7) ?? ""})`);
    this.intake.forTask(task, `${task.id} is merged into ${task.pr.base}. Thanks for asking!`);
    this.save(task);
    this.hooks.broadcast({ type: "toast", text: `${task.id} merged into ${task.pr.base}.`, taskId: task.id });
    this.store.savePrivate(task.id, { ...this.store.private(task.id), mergedAs: msg.commit ?? null });
    this.hooks.waitUntil(this.cleanup(task));
  }

  /** Removes a merged task's worktree once none of its sessions are still in it (the runner refuses otherwise). */
  private async cleanup(task: Task) {
    const priv = this.store.private(task.id);
    if (task.state !== "merged" || !task.machine || !priv.worktree || !priv.repoDir || priv.cleaned) return;
    const machine = (await this.hooks.machines()).find((m) => m.id === task.machine);
    if (machine?.sessions.some((s) => s.session.taskId === task.id)) return; // its last end calls this again
    this.store.savePrivate(task.id, { ...priv, cleaned: true });
    await this.toRunner(task.machine, {
      type: "task.cleanup",
      taskId: task.id,
      cwd: priv.worktree,
      repoDir: priv.repoDir,
      branch: task.pr?.branch ?? `agent/${branchName(task)}`,
      merged: true,
      heads: [task.pr?.head, priv.mergedAs].filter((h): h is string => Boolean(h)),
    });
  }

  // ---------------------------------------------------------------------------
  // Agents' tools

  private async tool(sessionId: string, name: string, args: Record<string, unknown>): Promise<Reply> {
    const s = this.store.session(sessionId);
    if (name === "tools/list") return { result: { summary: "", data: { tools: s ? toolsFor(s.role) : [] } } };
    if (!s) return { error: "This session isn't working on a factory task." };
    if (!allowed(s.role, name)) return { error: `${name} isn't one of the ${s.role}'s tools.` };
    const task = this.store.task(s.task);
    if (!task) return { error: "The task isn't there any more." };
    if (task.worker?.session !== sessionId) return { error: "This session isn't the task's current worker any more; stop here." };
    if (name !== "get_task" && this.store.private(task.id).handingOff) return { error: "The task is being handed off to another machine; stop here." };
    try {
      const out = this.run(task, s, name, args);
      this.save(task);
      if (name === "submit_review") await this.autoMerge(task);
      return { result: out };
    } catch (e) {
      return { error: e instanceof Error ? e.message : String(e) };
    }
  }

  private run(task: Task, s: TaskSession, name: string, a: Record<string, unknown>): { summary: string; data?: unknown } {
    const goal = this.store.goal(task.goal);
    switch (name) {
      case "get_task":
        return { summary: `${task.id} · ${task.title} (${task.state})`, data: { task, goal } };

      case "submit_plan": {
        if (task.state !== "planning") fail("The plan isn't open for changes right now.");
        const steps = arr(a.steps).map((x) => obj(x));
        const done = arr(a.doneWhen).map((x) => obj(x));
        if (!steps.length) fail("steps: at least one.");
        if (!done.length) fail("doneWhen: at least one.");
        const before = task.plan;
        task.plan = steps.map((st, i) => {
          const prev = before[i];
          const text = str(st.text, "steps[].text");
          return {
            text,
            file: str(st.file, "steps[].file"),
            progress: "pending",
            added: task.planVersion > 0 && !prev,
            from: prev && prev.text !== text ? prev.text : null,
          };
        });
        task.doneWhen = done.map((d) => ({ text: str(d.text, "doneWhen[].text"), proof: proofKind(d.proof), status: "pending", evidence: null }));
        task.planSummary = str(a.summary, "summary");
        task.planVersion += 1;
        const risk = obj(a.risk);
        const level = ["low", "medium", "high"].includes(risk.level as string) ? (risk.level as "low" | "medium" | "high") : "medium";
        task.risk = { level, reasons: arr(risk.reasons).map(String), areas: arr(risk.areas).map(String) };
        const fp = obj(a.footprint);
        task.footprint = { files: num(fp.files), lines: num(fp.lines), estimated: true };
        const version = task.planVersion;
        task.mockups = arr(a.mockups).map((x, i) => {
          const m = obj(x);
          return {
            id: `M${i + 1}`,
            title: str(m.title, "mockups[].title"),
            kind: m.kind === "terminal" ? "terminal" : "screen",
            url: typeof m.url === "string" ? m.url : null,
            html: typeof m.html === "string" ? m.html : null,
            lines: arr(m.lines).map((l) => {
              const line = obj(l);
              return { text: String(line.text ?? ""), style: String(line.style ?? "output"), callout: line.callout != null ? num(line.callout) : null };
            }),
            notes: arr(m.notes).map(String),
            status: "proposed",
            version,
            visualMatch: null,
            differences: [],
          } satisfies Mockup;
        });
        this.applyPolicy(task);
        task.approvals = [];
        for (const c of task.changes) if (c.status !== "applied") c.status = "applied";
        task.state = "awaitingApproval";
        this.event(task, "planner", task.planVersion > 1 ? `revised the plan (v${task.planVersion})` : "wrote the plan");
        this.closeWorker(task, "done");
        return { summary: `Plan v${task.planVersion} submitted for approval. Your work here is done; end your turn.` };
      }

      case "ask": {
        const question = str(a.question, "question");
        task.question = { text: question, options: arr(a.options).map(String), role: s.role, at: now() };
        this.event(task, s.role, `asked: ${question}`);
        this.intake.forTask(task, `${task.id}'s ${s.role} asks: ${question}`, true);
        this.hooks.broadcast({ type: "toast", text: `${task.id}'s ${s.role} has a question.`, taskId: task.id });
        return { summary: "Asked. End your turn now; the answer will be typed into this session." };
      }

      case "raise_hand": {
        const reason = ["proofBurden", "needsInput", "overBudget"].includes(a.reason as string) ? (a.reason as Hand["reason"]) : "needsInput";
        const options = arr(a.options).map((o) => {
          const x = obj(o);
          return { title: str(x.title, "options[].title"), detail: String(x.detail ?? ""), recommended: x.recommended === true };
        });
        task.hand = { reason, summary: str(a.summary, "summary"), at: now(), assignee: task.owner, options };
        this.event(task, s.role, "raised a hand");
        this.hooks.broadcast({ type: "toast", text: `${task.id} needs a hand.`, taskId: task.id });
        return { summary: "Hand raised. End your turn now; a person's decision will be typed into this session." };
      }

      case "progress": {
        if (a.step != null) {
          const step = task.plan[num(a.step) - 1] ?? fail(`There's no step ${a.step}; the plan has ${task.plan.length}.`);
          step.progress = a.status === "done" ? "done" : "active";
          if (step.progress === "active") for (const other of task.plan) if (other !== step && other.progress === "active") other.progress = "pending";
        }
        if (typeof a.note === "string" && a.note.trim()) task.liveLog = a.note.trim();
        for (const id of arr(a.applied).map(String)) {
          const c = task.changes.find((x) => x.id === id);
          if (c) {
            c.status = "applied";
            this.event(task, "builder", `applied ${c.author}'s change: ${c.text}`);
          }
        }
        const done = task.plan.filter((p) => p.progress === "done").length;
        return { summary: `Noted. ${done} of ${task.plan.length} steps done.` };
      }

      case "prove": {
        const item = task.doneWhen[num(a.item) - 1] ?? fail(`There's no item ${a.item}; Done when has ${task.doneWhen.length}.`);
        const evidence: Evidence = {
          kind: proofKind(a.kind ?? item.proof),
          summary: str(a.summary, "summary"),
          command: typeof a.command === "string" ? a.command : null,
          output: arr(a.output).map(String).slice(-60),
          passed: a.passed != null ? num(a.passed) : null,
          failed: a.failed != null ? num(a.failed) : null,
          file: null,
          by: "builder",
          at: now(),
        };
        item.evidence = evidence;
        item.status = evidence.failed ? "failed" : "proven";
        this.event(task, "builder", `${item.status === "proven" ? "proved" : "couldn't prove"} "${item.text}"`);
        const left = task.doneWhen.filter((d) => d.status !== "proven").length;
        return { summary: left ? `Attached. ${left} item${left === 1 ? "" : "s"} left to prove.` : "Attached. Every item is proven." };
      }

      case "finish": {
        if (task.state !== "building") fail("It isn't building.");
        const unproven = task.doneWhen.filter((d) => d.status !== "proven");
        if (unproven.length) fail(`Prove these first (or raise a hand): ${unproven.map((d) => `"${d.text}"`).join(", ")}.`);
        const priv = this.store.private(task.id);
        if (!priv.worktree || !priv.repoDir) fail("The factory doesn't know where this worktree came from; raise a hand.");
        this.store.savePrivate(task.id, { ...priv, finishing: true });
        task.liveLog = "Committing and pushing…";
        task.comments.push({ id: crypto.randomUUID(), author: "builder", text: str(a.summary, "summary"), at: now(), anchor: "Summary", via: null });
        this.hooks.waitUntil(this.toRunner(task.machine!, {
          type: "task.finish",
          taskId: task.id,
          cwd: priv.worktree!,
          repoDir: priv.repoDir!,
          branch: task.branch ?? `agent/${branchName(task)}`,
          base: priv.base ?? goal?.base ?? null,
          title: `${task.id}: ${task.title}`,
          fallback: true,
        }));
        return { summary: "Finishing: the factory is committing and pushing, then the review starts. End your turn now." };
      }

      case "submit_review": {
        const review = task.autoReview ?? fail("There's no review open.");
        const round = review.rounds.at(-1) ?? fail("There's no review round open.");
        if (round.verdict !== "inProgress") fail("This round is already in.");
        const check = (x: unknown): ReviewCheck => {
          const c = obj(x);
          const verdict = ["met", "partial", "missed"].includes(c.verdict as string) ? (c.verdict as ReviewCheck["verdict"]) : "partial";
          return { text: str(c.text, "text"), verdict, note: typeof c.note === "string" ? c.note : null };
        };
        review.ask = arr(a.ask).map(check);
        review.proofs = arr(a.proofs).map(check);
        review.summary = str(a.summary, "summary");
        for (const id of arr(a.fixed).map(String)) {
          const f = review.findings.find((x) => x.id === id);
          if (f) {
            f.status = "fixed";
            f.fixedIn = round.number;
          }
        }
        const found: Finding[] = arr(a.findings).map((x, i) => {
          const f = obj(x);
          return {
            id: `R${round.number}.${i + 1}`,
            kind: ["scope", "proof", "code", "risk"].includes(f.kind as string) ? (f.kind as Finding["kind"]) : "code",
            severity: ["blocker", "major", "minor"].includes(f.severity as string) ? (f.severity as Finding["severity"]) : "major",
            text: str(f.text, "findings[].text"),
            file: typeof f.file === "string" ? f.file : null,
            raisedIn: round.number,
            status: "open",
            fixedIn: null,
          };
        });
        review.findings.push(...found);
        const serious = review.findings.some((f) => f.status === "open" && f.severity !== "minor");
        round.verdict = a.verdict === "passed" && !serious ? "passed" : "changesRequested";
        round.found = found.length;
        round.at = now();
        this.closeWorker(task, "done");
        if (round.verdict === "passed") {
          this.event(task, "reviewer", `passed round ${round.number}`);
          this.hooks.broadcast({ type: "toast", text: `${task.id} passed review; it's ready for yours.`, taskId: task.id });
          return { summary: "Review in: passed. End your turn now." };
        }
        if (round.number >= review.maxRounds) {
          round.verdict = "escalated";
          this.raise(task, "reviewer", "reviewLoop", `${round.number} review rounds and it still has open findings.`);
          return { summary: "Review in. The rounds ran out, so a person takes it from here. End your turn now." };
        }
        round.fix = `${found.length} finding${found.length === 1 ? "" : "s"} to fix`;
        task.state = "building";
        this.event(task, "reviewer", `asked for changes in round ${round.number}`);
        this.hooks.waitUntil(this.pump());
        return { summary: "Review in: changes requested. The builder picks it up. End your turn now." };
      }
    }
    return fail(`Unknown tool ${name}.`);
  }

  // ---------------------------------------------------------------------------
  // Policy and merging

  private assessment(task: Task) {
    return assess(task, this.store.policy(), this.store.acceptances().find((a) => a.goal === task.goal));
  }

  /** The risk level, approvals and reviews the policy gives this task now. */
  private applyPolicy(task: Task) {
    const a = this.assessment(task);
    task.risk = { level: a.level, reasons: task.risk?.reasons ?? [], areas: task.risk?.areas ?? [] };
    task.approvalsNeeded = a.approvals;
    task.reviewsNeeded = a.reviews;
  }

  private async policyChanged() {
    this.hooks.broadcast({ type: "policy.updated", policy: this.store.policy(), acceptances: this.store.acceptances() });
    for (const task of this.store.tasks()) {
      if (task.state === "merged" || task.state === "cancelled" || !task.risk) continue;
      const before = `${task.risk.level}/${task.approvalsNeeded}/${task.reviewsNeeded}`;
      this.applyPolicy(task);
      if (`${task.risk.level}/${task.approvalsNeeded}/${task.reviewsNeeded}` === before) continue;
      this.save(task, false);
      if (task.state === "awaitingApproval" && task.approvals.length >= task.approvalsNeeded) {
        task.state = "building";
        this.event(task, "factory", "queued it for building (the policy needs fewer approvals now)");
        this.save(task);
      }
      await this.autoMerge(task);
    }
    await this.pump();
  }

  /** Merges on the factory's own say-so when the policy (or the goal's accepted risk) allows it. */
  private async autoMerge(task: Task) {
    if (task.state !== "reviewing" || !task.pr || task.autoReview?.rounds.at(-1)?.verdict !== "passed") return;
    if (task.reviews.length < task.reviewsNeeded || task.doneWhen.some((d) => d.status !== "proven")) return;
    if (task.pr.checks.some((c) => c.status !== "passed")) return; // CI first
    const a = this.assessment(task);
    if (!a.autoMerge || this.store.private(task.id).merging) return;
    await this.startMerge(task, "factory", a.accepted ? "auto-merged it (the goal accepted this risk)" : `auto-merged it (${a.level} risk)`).catch(() => {});
  }

  private async startMerge(task: Task, who: string, text = "merged it") {
    const priv = this.store.private(task.id);
    const app = githubApp(this.env);
    if (app && priv.gh && task.pr?.url) {
      // On GitHub: squash-merge the pull request, pinned to the head that was reviewed.
      this.store.savePrivate(task.id, { ...priv, merging: true });
      this.event(task, who, text);
      task.liveLog = "Merging…";
      this.save(task);
      await audit(this.env, who, "task.merged", task.id);
      const pr = task.pr;
      this.hooks.waitUntil(
        mergePullRequest(app, priv.gh.owner, priv.gh.repo, pr.number, { sha: pr.head ?? null, title: `${task.id}: ${task.title}` })
          .then((m) => this.merged({ type: "task.merged", taskId: task.id, ok: true, commit: m.sha, message: null }))
          .catch((e) => this.merged({ type: "task.merged", taskId: task.id, ok: false, commit: null, message: (e as Error).message })),
      );
      return;
    }
    if (!task.machine || !priv.worktree || !task.pr) fail("Its worktree isn't known; it can't be merged from here.");
    const sent = await this.toRunner(task.machine!, {
      type: "task.merge",
      taskId: task.id,
      cwd: priv.worktree!,
      branch: task.pr!.branch,
      base: task.pr!.base,
      title: `Merge ${task.id}: ${task.title}`,
    });
    if (!sent) fail(`${task.machine} is offline; it merges when it's back.`);
    this.store.savePrivate(task.id, { ...priv, merging: true });
    this.event(task, who, text);
    task.liveLog = "Merging…";
    this.save(task);
    await audit(this.env, who, "task.merged", task.id);
  }

  // ---------------------------------------------------------------------------
  // Helpers

  private raise(task: Task, role: Role | string, reason: Hand["reason"], summary: string) {
    task.hand = {
      reason,
      summary,
      at: now(),
      assignee: task.owner,
      options: [
        { title: "Retry", detail: "Start it again where it left off.", recommended: true },
        { title: "Cancel it", detail: "Stop the task; its branch stays.", recommended: false },
      ],
    };
    this.event(task, String(role), `stopped and needs a hand: ${summary}`);
    this.hooks.broadcast({ type: "toast", text: `${task.id} needs a hand: ${summary}`, taskId: task.id });
  }

  /** Ends the task's current session on purpose: after its last word, or when it's cancelled. */
  /** Asks the task's machine to commit its work so far and push the branch, then move it
   *  (`task.handed_off`). False when there's no worktree to push from. */
  private async handOff(task: Task, who: string): Promise<boolean> {
    const priv = this.store.private(task.id);
    if (!task.machine || !priv.worktree || !priv.repoDir || task.state === "planning") return false;
    const sent = await this.toRunner(task.machine, {
      type: "task.handoff",
      taskId: task.id,
      cwd: priv.worktree,
      repoDir: priv.repoDir,
      branch: `agent/${branchName(task)}`,
      base: priv.base,
      title: task.title,
      fallback: true,
    });
    if (!sent) return false;
    this.store.savePrivate(task.id, { ...priv, handingOff: who });
    task.liveLog = "Pushing its work so far, to hand it off…";
    this.save(task);
    return true;
  }

  private handedOff(machine: string, msg: Extract<RunnerMessage, { type: "task.handed_off" }>) {
    const task = this.store.task(msg.taskId);
    const priv = task && this.store.private(task.id);
    if (!task || !priv?.handingOff) return;
    const who = priv.handingOff;
    this.store.savePrivate(task.id, { ...priv, handingOff: null });
    const nothing = !msg.ok && /nothing to carry/.test(msg.message ?? "");
    if (!msg.ok && !nothing) {
      task.liveLog = null;
      this.event(task, "factory", `couldn't hand it off (${msg.message ?? "no reason given"}); it stays on ${machine}`);
      this.save(task);
      return;
    }
    this.relocate(task, who, machine, msg.ok ? msg.commit ?? null : null);
    this.hooks.waitUntil(this.pump());
  }

  /** Frees a task from its machine: its next session starts on any free one, from what's pushed. */
  private relocate(task: Task, who: string, from: string, commit: string | null) {
    this.closeWorker(task, "moved");
    const priv = this.store.private(task.id);
    const carried = commit ?? task.pr?.head ?? null;
    this.store.savePrivate(task.id, { ...priv, worktree: null, repoDir: null, restarts: 0, finishing: false, movedFrom: { machine: from, commit: carried } });
    task.machine = null;
    task.hand = null;
    task.question = null;
    task.waiting = null;
    task.liveLog = null;
    this.event(task, who, commit
      ? `pushed its work so far (${commit.slice(0, 7)}) and moved it off ${from}`
      : carried
        ? `moved it off ${from}; it carries on from its last push (${carried.slice(0, 7)})`
        : `moved it off ${from}; it starts again from ${task.state === "planning" ? "the brief" : "its plan"}, since nothing was pushed`);
    this.save(task);
  }

  private closeWorker(task: Task, cause: string) {
    const w = task.worker;
    if (!w) return;
    this.store.endSession(w.session, cause);
    task.worker = null;
    if (cause !== "cancelled") task.liveLog = null;
    const kill = async () => {
      if (cause !== "cancelled") await new Promise((r) => setTimeout(r, CLOSE_AFTER_MS));
      await this.toRunner(w.machine, { type: "session.kill", id: w.session }, "factory");
    };
    this.hooks.waitUntil(kill());
  }

  /** A machine that's back can still be running sessions the factory ended while it was away
   *  (its task moved elsewhere); those stop now. */
  reap(machine: Machine) {
    for (const { session } of machine.sessions) {
      if (!session.taskId || this.reaped.has(session.id)) continue;
      const s = this.store.session(session.id);
      const task = s ? this.store.task(s.task) : null;
      // Ended here, or no task's worker: a leftover. Young ones may still be being registered.
      const orphan = s?.ended != null || (Date.now() - Number(session.startedAt) > REAP_AFTER_MS && task?.worker?.session !== session.id);
      if (!orphan) continue;
      this.reaped.add(session.id);
      this.hooks.waitUntil(this.toRunner(machine.id, { type: "session.kill", id: session.id }, "factory"));
    }
  }

  /** Sessions already sent a kill by `reap`, so a slow one isn't killed on every report. */
  private reaped = new Set<string>();

  /** Types into the task's live session, as if at its keyboard. False when nothing's running. */
  private async type(task: Task, text: string): Promise<boolean> {
    const w = task.worker;
    if (!w) return false;
    const res = await machineHub(this.env, w.machine).fetch("https://hub/input", { method: "POST", body: JSON.stringify({ session: w.session, text }) });
    return res.ok;
  }

  private async toRunner(machine: string, command: ServerToRunner, by?: string): Promise<boolean> {
    const res = await machineHub(this.env, machine).fetch("https://hub/command", {
      method: "POST",
      body: JSON.stringify(command),
      headers: by ? { "x-by": by } : {},
    });
    return res.ok;
  }

  private event(task: Task, who: string, text: string) {
    task.events.push({ who, text, at: now() });
    if (task.events.length > MAX_EVENTS) task.events.splice(0, task.events.length - MAX_EVENTS);
  }

  private save(task: Task, touch = true) {
    if (touch) task.updatedAt = now();
    this.store.saveTask(task);
    this.hooks.broadcast({ type: "task.updated", task });
  }
}

function sourceTitle(r: { source: string; channel?: string | null }) {
  const name = { slack: "Slack", linear: "Linear", jira: "Jira", api: "the API" }[r.source] ?? r.source;
  return r.channel ? `${name} ${r.channel}` : name;
}

function describeCause(end: SessionEnd) {
  switch (end.cause) {
    case "machineSlept": return "the machine slept";
    case "tmuxLost": return "tmux went away";
    case "runnerUpdated": return "the runner updated";
    case "signaled": return `signal ${end.signal ?? ""}`.trim();
    case "outOfMemory": return "out of memory";
    default: return end.cause;
  }
}

const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const num = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0;
};
const str = (v: unknown, name: string): string => (typeof v === "string" && v.trim() ? v.trim() : fail(`${name} is required.`));
const proofKind = (v: unknown): Evidence["kind"] => (["screenshot", "video", "terminal", "tests"].includes(v as string) ? (v as Evidence["kind"]) : "terminal");

/** The pull request's description: the brief, the plan, and what proves it's done. */
function pullBody(task: Task): string {
  const steps = task.plan.map((s, i) => `${i + 1}. ${s.text}${s.file ? ` (\`${s.file}\`)` : ""}`).join("\n");
  const proofs = task.doneWhen.map((d) => `- [${d.status === "proven" ? "x" : " "}] ${d.text}${d.evidence ? ` — ${d.evidence.summary}` : ""}`).join("\n");
  return [`Built by Maple Factory for **${task.id}**, owned by @${task.owner}.`, task.brief.trim(), steps && `## Plan\n\n${steps}`, proofs && `## Done when\n\n${proofs}`]
    .filter(Boolean)
    .join("\n\n")
    .slice(0, 60_000);
}
