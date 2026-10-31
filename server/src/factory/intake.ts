// Requests from outside the app: Slack, Linear, Jira or the API. Each keeps its conversation; the
// factory's bot answers in it (and back where it came from, through its reply URL) when someone
// takes the request on, asks a follow-up, or its task's agent has a question or merges.

import type { Goal, IntakeRequest, Task, TicketLink } from "../wire.ts";
import type { Store } from "./store.ts";

export interface NewRequest {
  source: string;
  channel?: string | null;
  requester: string;
  title: string;
  text: string;
  tickets?: TicketLink[];
  /// Where the bot's replies go (a Slack response_url, a webhook); kept server-side.
  replyUrl?: string | null;
}

const WORDS = /[a-z0-9]{4,}/g;
const words = (s: string) => new Set(s.toLowerCase().match(WORDS) ?? []);
const overlap = (a: Set<string>, b: Set<string>) => [...a].filter((w) => b.has(w)).length;

export class Intake {
  constructor(
    private store: Store,
    private hooks: { broadcast(request: IntakeRequest): void; waitUntil(p: Promise<unknown>): void; deliver(replyUrl: string, text: string): Promise<void> },
  ) {}

  list(): IntakeRequest[] {
    return this.store.intake();
  }

  get(id: string): IntakeRequest | null {
    return this.store.intakeRequest(id);
  }

  create(input: NewRequest): IntakeRequest {
    // An issue labelled again (or its webhook sent twice) is the request it already is.
    const known = input.replyUrl ? this.store.intakeByReplyUrl(input.replyUrl) : null;
    const existing = known ? this.get(known) : null;
    if (existing) return existing;
    const text = `${input.title}\n${input.text}`;
    const request: IntakeRequest = {
      id: this.store.nextId("REQ"),
      source: input.source,
      channel: input.channel ?? null,
      requester: input.requester,
      title: input.title.slice(0, 200),
      at: Date.now(),
      thread: [{ author: input.requester, text: input.text || input.title, at: Date.now(), bot: false, relayedFrom: null }],
      tickets: input.tickets ?? [],
      status: "new",
      taskId: null,
      suggestedGoal: this.guessGoal(text)?.id ?? null,
      relatedTask: this.related(text)?.id ?? null,
      gaps: input.text.trim().length < 40 ? ["What should be true when it's done?"] : [],
    };
    this.save(request, input.replyUrl ?? null);
    return request;
  }

  /** A reply from where a request came from (a comment on its issue), if it's one of ours. */
  replyFrom(replyUrl: string, author: string, text: string): IntakeRequest | null {
    const id = this.store.intakeByReplyUrl(replyUrl);
    return id ? this.reply(id, author, text) : null;
  }

  /** Someone on the requester's side answered in the thread. */
  reply(id: string, author: string, text: string): IntakeRequest | null {
    const request = this.get(id);
    if (!request) return null;
    request.thread.push({ author, text, at: Date.now(), bot: false, relayedFrom: null });
    if (request.status === "clarifying") request.status = "new";
    request.gaps = [];
    this.save(request);
    return request;
  }

  /** The bot says something in the thread, and where the request came from. */
  say(request: IntakeRequest, text: string, relayedFrom: string | null = null) {
    request.thread.push({ author: "maple", text, at: Date.now(), bot: true, relayedFrom });
    this.save(request);
    const url = this.store.intakeReplyUrl(request.id);
    if (url) {
      this.hooks.waitUntil(this.hooks.deliver(url, text).catch(() => {}));
    }
  }

  accepted(request: IntakeRequest, task: Task, how: "created" | "attached", by: string) {
    request.status = "accepted";
    request.taskId = task.id;
    // A Slack thread can't answer the agent (its replies don't come back), so it's told where to.
    const questions = this.store.intakeReplyUrl(request.id)?.startsWith("slack:")
      ? "Its agent's questions show up here (answer them in the factory)"
      : "Questions from its agent come here";
    this.say(request, how === "created"
      ? `${by} is tracking this as ${task.id}${task.state === "planning" ? "; a planner is on it" : ""}. ${questions}, and this thread hears when it merges.`
      : `${by} added this to ${task.id}, whose agent reads it as context. This thread hears when it merges.`);
  }

  ask(request: IntakeRequest, text: string) {
    request.status = "clarifying";
    this.say(request, text);
  }

  decline(request: IntakeRequest, by: string, note: string | null) {
    request.status = "declined";
    this.say(request, `${by} passed on this for now${note ? `: ${note.replace(/[.!]?$/, ".")}` : "."} Reply here if it becomes urgent.`);
  }

  /** A task's news for the request it came from, if any. */
  forTask(task: Task, text: string, relayed = false) {
    const request = task.intake ? this.get(task.intake) : null;
    if (request) this.say(request, text, relayed ? task.id : null);
  }

  private save(request: IntakeRequest, replyUrl?: string | null) {
    this.store.saveIntake(request, replyUrl);
    this.hooks.broadcast(request);
  }

  private guessGoal(text: string): Goal | null {
    const asked = words(text);
    let best: Goal | null = null;
    let score = 0;
    for (const goal of this.store.goals()) {
      const s = overlap(asked, words(`${goal.name} ${goal.summary}`));
      if (s > score) [best, score] = [goal, s];
    }
    return best ?? this.store.goals()[0] ?? null;
  }

  private related(text: string): Task | null {
    const asked = words(text);
    let best: Task | null = null;
    let score = 1;
    for (const task of this.store.tasks()) {
      if (task.state === "merged" || task.state === "cancelled" || task.state === "closed") continue;
      const s = overlap(asked, words(`${task.title} ${task.brief}`));
      if (s > score) [best, score] = [task, s];
    }
    return best;
  }
}
