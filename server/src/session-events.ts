// Native session view relay rules (docs/native-session-view.md), kept pure so they can be tested:
// who may watch or type into a session, and which subscribed connections a runner's `session.events` reaches.

import type { Machine, Member, RunnerMessage_SessionEvents, ServerToClient_SessionEvents } from "./wire.ts";

/** What a member may do with one session: type into it (and watch), only watch, or nothing. */
export type SessionAccess = "type" | "watch" | null;

/** The /client/terminal rule: the machine's owner and admins type; a teammate with a share watches, and types
 *  when the share has `canType`; anyone else is refused. Shares live on the machine's live session. */
export function sessionAccess(machine: Machine | undefined, sessionId: string, member: Pick<Member, "login" | "role">): SessionAccess {
  if (!machine) return null;
  if (machine.owner === member.login || member.role === "admin") return "type";
  const share = machine.sessions.find((s) => s.session.id === sessionId)?.shares?.find((s) => s.login === member.login);
  if (!share) return null;
  return share.canType ? "type" : "watch";
}

/** The refusal for someone with no access, worded as the terminal's 403. */
export function refusal(machine: Pick<Machine, "owner" | "name" | "id">): string {
  return `Only ${machine.owner} or an admin can open terminals on ${machine.name ?? machine.id}; ask ${machine.owner} to share this session with you.`;
}

/** The refusal for a watch-only share that tried to type. */
export function watchOnly(machine: Pick<Machine, "owner">): string {
  return `You can watch this session but not type into it; ask ${machine.owner} to let you type.`;
}

/** One connection's subscription to one session's events; `nonce` names the backfill it asked for last. */
export interface EventSub {
  machine: string;
  id: string;
  nonce: string;
}

/** A subscribed connection, as the hub sees it: who it is and what it follows. */
export interface Subscriber<T> {
  conn: T;
  member: Pick<Member, "login" | "role">;
  events: EventSub[];
}

/** Which connections a runner's `session.events` goes to. A backfill only to the subscription whose nonce it
 *  echoes; live events to every subscriber of the session. Either way only while their access still holds,
 *  read from the machine as it is now, so a share taken back stops at the next message. */
export function recipients<T>(machine: Machine | undefined, msg: Pick<RunnerMessage_SessionEvents, "id" | "nonce" | "backfill">, subs: Subscriber<T>[]): T[] {
  if (!machine) return [];
  const out: T[] = [];
  for (const sub of subs) {
    const mine = sub.events.find((e) => e.machine === machine.id && e.id === msg.id);
    if (!mine) continue;
    if (msg.nonce ? mine.nonce !== msg.nonce : msg.backfill) continue;
    if (!sessionAccess(machine, msg.id, sub.member)) continue;
    out.push(sub.conn);
  }
  return out;
}

/** The apps' copy: with the machine, without the runner's nonce and cursor. */
export function toClient(msg: RunnerMessage_SessionEvents, machine: string): ServerToClient_SessionEvents {
  return { type: "session.events", machine, id: msg.id, events: msg.events, backfill: msg.backfill, nextSeq: msg.nextSeq, epoch: msg.epoch };
}
