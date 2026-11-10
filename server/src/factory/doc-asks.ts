// Ask an agent from a doc selection (MF-366, docs/planning-docs.md): the pure pieces the engine's ask()
// uses, kept here so they're unit-testable. An ask is an interactive agent session on one of the asker's
// machines (or one a teammate lends) whose prompt is the doc, the selected quote and the thread; it answers
// only through the doc tools (reply_to_doc_thread, suggest_doc_edit) and never edits files.
import type { AgentState, DocAgentRun, DocAgentStatus, DocThread, Machine } from "../wire.ts";

/** The id an ask's worktree / runner task goes by. */
export const ASK_PREFIX = "ask-";
/** Roles an ask can take. */
export const ASK_ROLES = ["planner", "researcher"] as const;
export type AskRole = (typeof ASK_ROLES)[number];
/** Live asks one member may have running at once. */
export const MAX_LIVE_ASKS = 3;

/** The record kept for an ask's session (kv `docask:<session>`). */
export interface AskRecord {
  session: string;
  doc: string;
  thread: string;
  by: string;
  role: AskRole;
  machine: string;
  agent: string;
  startedAt: number;
  costUsd: number;
  /** The session is gone (ended, stopped, killed). */
  ended: boolean;
  /** When the agent's turn ended and it went quiet (null while it works): the thread shows Done, and the
   *  session stays open for follow-ups until IDLE_GRACE_MS passes. */
  idleSince?: number | null;
  /** Time spent idle before the current turn, left out of the minute budget. */
  idleMs?: number;
  /** When a follow-up was last typed in: a 'done' before the runner reports work again is the previous turn's. */
  typedAt?: number | null;
  /** When the current turn began (the last follow-up typed in, else startedAt): Done needs a reply since then. */
  turnAt?: number | null;
  /** When it last replied in a thread or suggested an edit: Done needs this at or after turnAt. */
  repliedAt?: number | null;
}

/** How long after typing a follow-up a 'done' with no 'working' in between is taken as stale. */
export const TYPED_GRACE_MS = 10_000;

/** The agent label its doc-tool calls carry, which marks its comments in threads. */
export const agentLabel = (r: { role: AskRole; by: string }): string => `${r.role} for @${r.by}`;

/** The doc tools that count as answering in the doc (a thread reply or a suggestion). */
export const ANSWER_TOOLS = ["reply_to_doc_thread", "suggest_doc_edit"];

/** How long an answered ask's session stays open for follow-up replies before it's closed. */
export const IDLE_GRACE_MS = 15 * 60_000;

/** Whether an ask is working (counts toward the live limit and the budget): open and not idle. */
export const working = (r: AskRecord): boolean => !r.ended && !r.idleSince;

/** Whether an answered ask's session has been idle past the grace period. */
export const idleExpired = (r: AskRecord, at = Date.now(), grace = IDLE_GRACE_MS): boolean => !r.ended && !!r.idleSince && at - r.idleSince >= grace;

export const role = (r: unknown): AskRole => (r === "researcher" ? "researcher" : "planner");

/** Whether a run's session is still going. */
export const live = (run: DocAgentRun | null | undefined): boolean => !!run && !["done", "stopped", "failed"].includes(run.status);

export interface Pick { machine: Machine; kind: "personal" | "team" }

export interface PickDeps {
  paused(m: Machine): boolean;
  hasAgent(m: Machine, agent: string): boolean;
  overCap(m: Machine, agent: string, owner: string): string | null;
  lends(m: Machine, owner: string): boolean;
  busy(m: Machine): number;
}

/** The machine an ask runs on: the asker's own online, unpaused machines with the agent and under their caps,
 *  least busy first; then a machine a teammate lends. A string says why none will do. */
export function pickMachine(machines: Machine[], asker: string, agent: string, d: PickDeps): Pick | string {
  const fits = (m: Machine) => m.online && !d.paused(m) && d.hasAgent(m, agent) && !d.overCap(m, agent, asker);
  const byLoad = (a: Machine, b: Machine) => d.busy(a) - d.busy(b);
  const own = machines.filter((m) => m.owner === asker && fits(m)).sort(byLoad)[0];
  if (own) return { machine: own, kind: "personal" };
  const lent = machines.filter((m) => m.owner !== asker && fits(m) && d.lends(m, asker)).sort(byLoad)[0];
  if (lent) return { machine: lent, kind: "team" };
  const mine = machines.filter((m) => m.owner === asker);
  if (!mine.length) return "You have no machines to run an agent on: add one under Machines.";
  const online = mine.filter((m) => m.online);
  if (!online.length) return `Your machines (${mine.map((m) => m.name).join(", ")}) are offline, and no teammate's machine is free.`;
  const running = online.filter((m) => !d.paused(m));
  if (!running.length) return `Your machines (${online.map((m) => m.name).join(", ")}) are paused, and no teammate's machine is free. No agent was started.`;
  const withAgent = running.filter((m) => d.hasAgent(m, agent));
  if (!withAgent.length) return `None of your online machines has ${agent} installed.`;
  const capped = withAgent.map((m) => d.overCap(m, agent, asker)).find(Boolean);
  return `${capped ?? "Your machines are over their usage caps."} No agent was started.`;
}

/** Why a member can't start another ask, or null. */
export function overLimit(records: AskRecord[], by: string, max = MAX_LIVE_ASKS): string | null {
  const mine = records.filter((r) => r.by === by && working(r)).length;
  return mine >= max ? `You already have ${mine} agents running in docs; stop one or wait for it to finish.` : null;
}

/** Whether a run is past the budget: minutes since it started, or what it spent. */
export function overBudget(r: AskRecord, limits: { minutes: number | null; costUsd: number | null }, at = Date.now()): "time" | "cost" | null {
  const busy = at - r.startedAt - (r.idleMs ?? 0) - (r.idleSince ? at - r.idleSince : 0);
  if (limits.minutes != null && busy >= limits.minutes * 60_000) return "time";
  if (limits.costUsd != null && r.costUsd >= limits.costUsd) return "cost";
  return null;
}

/** The thread status for a runner activity. */
export function statusFor(state: AgentState, message?: string | null): DocAgentStatus {
  if (state === "waiting") return "waiting";
  if (state === "working") return message ? "working" : "thinking";
  if (state === "done") return "done"; // the turn ended: answered; the session stays open for follow-ups
  return "thinking"; // idle: not started on it yet
}

/** The thread's transcript, oldest first. */
export function transcript(t: DocThread): string {
  return t.comments.map((c) => `- ${c.author}${c.agent ? ` (${c.agent})` : ""}: ${c.text.replace(/\n/g, "\n  ")}`).join("\n");
}

export interface PromptInput {
  doc: { id: string; title: string };
  markdown: string | null;
  thread: DocThread;
  role: AskRole;
  by: string;
  repo: string | null;
  goal: string | null;
}

export function askPrompt(p: PromptInput): string {
  const quote = p.thread.anchor?.quote?.trim();
  const who = p.role === "researcher"
    ? "You're the researcher: dig into the question, read the code and the web as needed, and report what you found with sources."
    : "You're the planner: think the question through, weigh options, and propose concrete wording or structure for the doc.";
  return [
    `@${p.by} asked you about the shared doc "${p.doc.title}" (doc ${p.doc.id}), in its comment thread ${p.thread.id}. ${who}`,
    p.repo ? `The doc belongs to the goal ${p.goal}; you're in a checkout of ${p.repo}, so read its code for context.` : "The doc isn't in a goal with a repo; answer from the doc, your knowledge and the web.",
    quote ? `The selected text:\n> ${quote.replace(/\n/g, "\n> ")}` : "",
    `The thread so far:\n${transcript(p.thread)}`,
    p.markdown ? `The doc as it is now (read_doc shows it again with block ids):\n\n${p.markdown}` : "Call read_doc to see the doc.",
    [
      "How to answer:",
      `- Answer only in that thread, with reply_to_doc_thread (doc ${p.doc.id}, thread ${p.thread.id}). Keep it short and plain.`,
      "- To propose new wording, call suggest_doc_edit anchored on the selected text (its quote) or a block: a person accepts or rejects it. A diagram goes in a suggestion as a ```mermaid block.",
      "- Never edit, create or commit files, and don't push anything. You may read code and search the web.",
      "- When you've answered, stop. People may reply in the thread; their replies are typed into this session, so answer each with reply_to_doc_thread too.",
    ].join("\n"),
  ].filter(Boolean).join("\n\n");
}

/** What a reply in a thread with a live ask types into its session. */
export function followUp(by: string, thread: string, doc: string, text: string): string {
  return `${by} in doc thread ${thread}: ${text.trim()}\n(Answer with reply_to_doc_thread, doc ${doc}, thread ${thread}.)`;
}

/** The doc-only agent mentions a doc comment can address: @planner, @researcher. Task-comment roles stay in mentions.ts. */
export { docAgentsIn } from "./mentions.ts";
