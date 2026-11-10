// Doc decisions (MF-367, docs/planning-docs.md): the pure lifecycle OrgHub and the agents' propose_decision use,
// kept here so it's unit-testable. A decision is proposed, then accepted or rejected by a person; an accepted
// decision can later be superseded by a newer accepted one (which names it in `supersedes`). Every transition
// returns the next Decision plus the DecisionEvent to append to the server-side, append-only log, and
// fold(events) rebuilds a decision from that log alone.
import type { Decision, DecisionAction, DecisionEvent, DecisionOption } from "../wire.ts";
import { mentionsIn } from "./mentions.ts";

export const MAX_QUESTION = 500;
export const MAX_RATIONALE = 10_000;
export const MAX_WHY = 2_000;
export const MIN_OPTIONS = 2;
export const MAX_OPTIONS = 10;
export const MAX_OPTION_LABEL = 300;
export const MAX_OPTION_NOTE = 2_000;

/** An event before the store numbers it. */
export type NewEvent = Omit<DecisionEvent, "seq">;
export type Change = { decision: Decision; event: NewEvent };
export type Result = Change | { error: string };

export type DecisionInput = { question: string; options: DecisionOption[]; chosen?: string | null; rationale?: string | null };

/** Why a decision's content won't do, or null. */
export function invalid(input: DecisionInput): string | null {
  const question = typeof input.question === "string" ? input.question.trim() : "";
  if (!question) return "A decision needs a question.";
  if (question.length > MAX_QUESTION) return `A decision's question is at most ${MAX_QUESTION} characters.`;
  if (!Array.isArray(input.options) || input.options.length < MIN_OPTIONS || input.options.length > MAX_OPTIONS) {
    return `A decision needs ${MIN_OPTIONS} to ${MAX_OPTIONS} options.`;
  }
  const ids = new Set<string>();
  for (const o of input.options) {
    if (!o || typeof o.id !== "string" || !o.id || o.id.length > 64) return "Each option needs an id.";
    if (ids.has(o.id)) return "Two options share an id.";
    ids.add(o.id);
    if (typeof o.label !== "string" || !o.label.trim()) return "Each option needs a label.";
    if (o.label.length > MAX_OPTION_LABEL) return `An option's label is at most ${MAX_OPTION_LABEL} characters.`;
    if (o.note != null && (typeof o.note !== "string" || o.note.length > MAX_OPTION_NOTE)) return `An option's note is at most ${MAX_OPTION_NOTE} characters.`;
  }
  const rationale = input.rationale ?? "";
  if (typeof rationale !== "string" || rationale.length > MAX_RATIONALE) return `A rationale is at most ${MAX_RATIONALE} characters.`;
  if (input.chosen != null && !ids.has(input.chosen)) return "The chosen option isn't one of the options.";
  return null;
}

function clean(input: DecisionInput) {
  return {
    question: input.question.trim(),
    options: input.options.map((o) => ({ id: o.id, label: o.label.trim(), note: o.note?.trim() || null })),
    chosen: input.chosen ?? null,
    rationale: (input.rationale ?? "").trim(),
  };
}

function cleanWhy(why?: string | null): string | null | { error: string } {
  if (why == null) return null;
  if (typeof why !== "string") return { error: "That reason isn't text." };
  if (why.length > MAX_WHY) return { error: `A reason is at most ${MAX_WHY} characters.` };
  return why.trim() || null;
}

function event(action: DecisionAction, by: string, at: number, before: Decision | null, after: Decision, extra: { agent?: string | null; why?: string | null } = {}): NewEvent {
  return { decision: after.id, at, by, agent: extra.agent ?? null, action, why: extra.why ?? null, before, after };
}

export function propose(
  id: string, doc: string, input: DecisionInput & { supersedes?: string | null },
  by: string, opts: { goal?: string | null; agent?: string | null; at?: number } = {},
): Result {
  const bad = invalid(input);
  if (bad) return { error: bad };
  if (input.supersedes === id) return { error: "A decision can't supersede itself." };
  const at = opts.at ?? Date.now();
  const decision: Decision = {
    id, doc, goal: opts.goal ?? null, ...clean(input), status: "proposed",
    proposedBy: by, agent: opts.agent ?? null, proposedAt: at,
    decidedBy: null, decidedAt: null, why: null, supersedes: input.supersedes ?? null, supersededBy: null,
  };
  return { decision, event: event("proposed", by, at, null, decision, { agent: opts.agent }) };
}

export function edit(d: Decision, input: DecisionInput, by: string, at = Date.now()): Result {
  if (d.status !== "proposed") return { error: `That decision was already ${d.status}; it can't be edited.` };
  const bad = invalid(input);
  if (bad) return { error: bad };
  const decision: Decision = { ...d, ...clean(input) };
  return { decision, event: event("edited", by, at, d, decision) };
}

/** Accept `d`. When it supersedes another decision, pass that one as `target`: it must be accepted, and it
 *  moves to superseded in the same step (both changes come back, `d`'s first). */
export function accept(
  d: Decision, by: string, opts: { chosen?: string | null; why?: string | null; at?: number } = {}, target?: Decision | null,
): Change[] | { error: string } {
  if (d.status !== "proposed") return { error: `That decision was already ${d.status}.` };
  const chosen = opts.chosen ?? d.chosen ?? null;
  if (!chosen) return { error: "Pick the chosen option before accepting." };
  if (!d.options.some((o) => o.id === chosen)) return { error: "The chosen option isn't one of the options." };
  const why = cleanWhy(opts.why);
  if (why && typeof why === "object") return why;
  if (d.supersedes) {
    if (!target || target.id !== d.supersedes) return { error: "The decision it supersedes is gone." };
    if (target.status !== "accepted") return { error: `The decision it supersedes is ${target.status}, not accepted.` };
  }
  const at = opts.at ?? Date.now();
  const decision: Decision = { ...d, chosen, status: "accepted", decidedBy: by, decidedAt: at, why };
  const out: Change[] = [{ decision, event: event("accepted", by, at, d, decision, { why }) }];
  if (d.supersedes && target) {
    const old: Decision = { ...target, status: "superseded", supersededBy: d.id };
    out.push({ decision: old, event: event("superseded", by, at, target, old) });
  }
  return out;
}

export function reject(d: Decision, by: string, opts: { why?: string | null; at?: number } = {}): Result {
  if (d.status !== "proposed") return { error: `That decision was already ${d.status}.` };
  const why = cleanWhy(opts.why);
  if (why && typeof why === "object") return why;
  const at = opts.at ?? Date.now();
  const decision: Decision = { ...d, status: "rejected", decidedBy: by, decidedAt: at, why };
  return { decision, event: event("rejected", by, at, d, decision, { why }) };
}

/** Rebuild a decision from its log alone, checking each event follows from the one before (a gap or an
 *  edited entry throws). Null for an empty log. */
export function fold(events: DecisionEvent[]): Decision | null {
  let d: Decision | null = null;
  for (const e of events) {
    if (!e.after || e.after.id !== e.decision) throw new Error(`decision log #${e.seq} has no state`);
    if (e.action === "proposed" ? d !== null : JSON.stringify(e.before ?? null) !== JSON.stringify(d)) {
      throw new Error(`decision log #${e.seq} doesn't follow the entry before it`);
    }
    d = e.after;
  }
  return d;
}

export function isOpen(d: Decision): boolean {
  return d.status === "proposed";
}

/** The markdown export line for a decision embed. */
export function markdownLine(d: Decision | undefined, id: string): string {
  if (!d) return `> [!DECISION] ${id}`;
  const chosen = d.options.find((o) => o.id === d.chosen)?.label;
  return `> [!DECISION] ${id} · ${d.question} · ${d.status}${chosen && d.status !== "proposed" ? ` → ${chosen}` : ""}`;
}

/** Who a newly proposed decision pushes to (reason `decision`, ref `doc:<id>`): the org members @mentioned in its
 *  question, rationale or option notes, once each, never the proposer. An agent's proposal also goes to
 *  `proposedBy`, the person it works for, when that's a member. */
export function pushTargets(d: Decision, members: { login: string }[]): string[] {
  const text = [d.question, d.rationale, ...d.options.map((o) => o.note ?? "")].join("\n");
  const person = d.agent ? members.find((m) => m.login.toLowerCase() === d.proposedBy.toLowerCase())?.login : undefined;
  const mentioned = mentionsIn(text, members, d.proposedBy);
  return person ? [person, ...mentioned] : mentioned;
}

/** Push a newly proposed decision to pushTargets; Push.send skips quiet hours and a relay that's off. */
export async function notifyProposed(
  push: { send(login: string, what: { ref: string; reason: "decision" }): Promise<number> },
  d: Decision, members: { login: string }[],
): Promise<number> {
  let sent = 0;
  for (const login of pushTargets(d, members)) sent += await push.send(login, { ref: `doc:${d.doc}`, reason: "decision" });
  return sent;
}
