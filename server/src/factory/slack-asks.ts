// @Maple in Slack: a mention becomes an ask. An agent on an online machine reads the code of the
// channel's best-suited goal, unable to change anything (the runner's `draft.run`, under a `slack-` id,
// as Scout does), and answers the thread; when it proposes a task, the answer carries Create task and
// Not now buttons, and Create task makes it in the proposed goal (the engine's `make`). Asks live in the
// OrgHub's kv for 30 minutes; each channel's goals (picked when Maple joins it) live there too.

import type { Goal, Machine, ServerToRunner, Task } from "../wire.ts";
import { postMessage, updateMessage, type Blocks, type SlackAction, type SlackAsk, type SlackAttachment } from "../slack.ts";
import { lastJson } from "./drafts.ts";
import { goalMayFetch } from "./repos.ts";
import type { Store } from "./store.ts";
import { LINK_HINT, mineSummary, wantsStatus, workSummary } from "./slack-status.ts";
import { wantsMine } from "../slack-links.ts";

/** The id an ask goes by on the runner (its token requests and its worktree's name). */
export const SLACK_PREFIX = "slack-";

/** How long an ask waits for its answer, and an answer's buttons stay good. */
export const ASK_MS = 30 * 60_000;

/** The picker's choice for every active goal. */
const ANY = "*";

export const ARCHIVED_NOTE = "This channel's goals are archived; mention me with `goals` to pick again.";

/** The task an answer proposes. */
export type Proposal = { goal: string; title: string; brief: string; doneWhen: string[] };

export type Ask = {
  id: string;
  machine: string;
  /** Whose machine answered: the task's owner if one is made. */
  owner: string;
  agent: string;
  channel: string;
  threadTs: string;
  /** The bot's "Looking into it…" message, replaced by the answer. */
  replyTs: string;
  requester: string;
  /** The asker's factory login, when their Slack account is linked. */
  login: string | null;
  question: string;
  thread: SlackAsk["thread"];
  attachments: SlackAttachment[];
  /** The channel's goals it may propose a task in, and the one whose code it reads. */
  goals: string[];
  goal: string;
  state: "running" | "answered" | "created" | "dismissed";
  proposal: Proposal | null;
  /** The reply as it was posted, kept so the card under it can change. */
  answer: string | null;
  /** Said once under the answer: the channel's goals are all archived. */
  note: string | null;
  task: string | null;
  expiresAt: number;
};

type Deps = {
  machines(): Promise<Machine[]>;
  hasAgent(machine: Machine, agent: string): boolean;
  paused(machine: Machine): boolean;
  toRunner(machine: string, command: ServerToRunner): Promise<boolean>;
  /** The bot token, if Slack has one. */
  token(): Promise<string | null>;
  /** Something Slack refused, for the integration's status. */
  problem(text: string): void;
  /** Makes the proposed task and starts its planning; throws with a message for the thread. `onMade` is
   *  called once the task is saved, so a throw after it (its planning) doesn't leave the task unknown. */
  make(ask: Ask, proposal: Proposal, by: string, channelName: string | null, onMade: (task: Task) => void): Promise<Task>;
  /** The factory login a Slack user linked (slack-links.ts), else null. */
  loginFor(team: string, slackUser: string): Promise<string | null>;
  /** Deletes attachments (their `/attachments/<id>/<name>` paths) from the bucket. */
  forget(paths: string[]): void;
  /** Call `sweep` again in about `ms`. */
  wakeIn(ms: number): void;
};

const WORDS = /[a-z0-9]{4,}/g;
const words = (s: string) => new Set(s.toLowerCase().match(WORDS) ?? []);

/** The answer and the task it proposes, if it does in one of `goals`. */
export function parseAnswer(output: string, goals: Goal[]): { answer: string; proposal: Proposal | null } | null {
  const reply = lastJson(output);
  const answer = typeof reply?.answer === "string" ? reply.answer.trim() : "";
  if (!reply || !answer) return null;
  const p = reply.proposal && typeof reply.proposal === "object" ? (reply.proposal as Record<string, unknown>) : null;
  const named = typeof p?.goal === "string" ? p.goal.trim() : "";
  const goal = goals.find((g) => g.id === named || g.name.toLowerCase() === named.toLowerCase() || g.prefix === named.toUpperCase());
  const title = typeof p?.title === "string" ? p.title.trim() : "";
  const brief = typeof p?.brief === "string" ? p.brief.trim() : "";
  const doneWhen = (Array.isArray(p?.doneWhen) ? p.doneWhen : []).filter((d): d is string => typeof d === "string" && !!d.trim()).map((d) => d.trim()).slice(0, 12);
  const proposal = goal && title && brief ? { goal: goal.id, title: title.slice(0, 120), brief: brief.slice(0, 20_000), doneWhen } : null;
  return { answer: answer.slice(0, 12_000), proposal };
}

/** Text as section blocks, each under Slack's 3000 characters. */
function sections(said: string): Blocks {
  const out: Blocks = [];
  for (let rest = said; rest; ) {
    let cut = rest.length <= 2900 ? rest.length : rest.lastIndexOf("\n", 2900);
    if (cut < 1000) cut = Math.min(rest.length, 2900);
    out.push({ type: "section", text: { type: "mrkdwn", text: rest.slice(0, cut) } });
    rest = rest.slice(cut).replace(/^\n+/, "");
  }
  return out;
}

const context = (said: string) => ({ type: "context", elements: [{ type: "mrkdwn", text: said }] });

/** The proposed task's card: its buttons, or once one is clicked, `footer` where they were. */
function card(ask: Ask, goal: Goal | null, footer: string | null): Blocks {
  const p = ask.proposal!;
  const checks = p.doneWhen.length ? `\n*Done when*\n${p.doneWhen.map((d) => `• ${d}`).join("\n")}` : "";
  const blocks: Blocks = [
    { type: "divider" },
    { type: "section", text: { type: "mrkdwn", text: `*Proposed task* in ${goal?.name ?? "its goal"}\n*${p.title}*${checks}`.slice(0, 2990) } },
  ];
  if (footer) blocks.push(context(footer));
  else blocks.push({
    type: "actions",
    elements: [
      { type: "button", action_id: "slack.create", text: { type: "plain_text", text: "Create task" }, style: "primary", value: ask.id },
      { type: "button", action_id: "slack.dismiss", text: { type: "plain_text", text: "Not now" }, value: ask.id },
    ],
  });
  return blocks;
}

export class SlackAsks {
  constructor(private store: Store, private deps: Deps) {}

  private load(id: string): Ask | null {
    const raw = this.store.get(`slack:ask:${id}`);
    return raw ? (JSON.parse(raw) as Ask) : null;
  }

  private ids(): string[] {
    return JSON.parse(this.store.get("slack:asks") ?? "[]");
  }

  /** Saves an ask, and forgets the ones whose time ran out. */
  private save(ask: Ask) {
    this.store.set(`slack:ask:${ask.id}`, JSON.stringify(ask));
    this.prune(ask.id);
  }

  /** Forgets the asks whose time ran out (but `keep`), and the files of those that never became a task. */
  private prune(keep: string | null = null) {
    const ids = this.ids();
    const kept: string[] = [];
    for (const id of ids) {
      const ask = this.load(id);
      if (id === keep || (ask && ask.expiresAt > Date.now())) kept.push(id);
      else {
        if (ask && !ask.task) this.forget(ask);
        this.store.delete(`slack:ask:${id}`);
      }
    }
    if (keep && !kept.includes(keep)) kept.push(keep);
    this.store.set("slack:asks", JSON.stringify(kept));
  }

  /** Deletes an ask's files from the bucket: it won't become a task. */
  private forget(ask: Ask) {
    if (ask.attachments.length) this.deps.forget(ask.attachments.map((f) => f.path));
    ask.attachments = [];
  }

  /** The asks still waiting on their answer. */
  private running(): Ask[] {
    return this.ids().map((id) => this.load(id)).filter((a): a is Ask => a?.state === "running");
  }

  /** When @Maple was last mentioned, if ever. */
  lastMention(): number | null {
    const at = Number(this.store.get("slack:lastMention"));
    return at || null;
  }

  /** The Slack integration's status line, with the bot token: its channels and its last mention. */
  status(): string {
    const n = this.channels().length;
    if (!n) return "Invite @Maple to a public channel: /invite @Maple";
    const at = this.lastMention();
    const day = at ? new Date(at).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" }) : null;
    return `@Maple is in ${n} channel${n === 1 ? "" : "s"}${day ? ` · last mentioned ${day}` : ""}.`;
  }

  /** A machine went offline: its running asks won't be answered, so their threads hear it. */
  async machineGone(machine: string, name: string) {
    for (const ask of this.running()) {
      if (ask.machine !== machine || ask.expiresAt <= Date.now()) continue;
      ask.state = "answered";
      this.save(ask);
      await this.update(ask.channel, ask.replyTs, `${name} went offline before answering. Mention me again in a moment.`);
    }
  }

  /** The alarm: asks whose answer never came say so, once; expired asks are forgotten; and the next expiry is woken for. */
  async sweep() {
    for (const ask of this.running()) {
      if (ask.expiresAt > Date.now()) continue;
      ask.state = "answered";
      this.store.set(`slack:ask:${ask.id}`, JSON.stringify(ask));
      await this.update(ask.channel, ask.replyTs, "I didn't hear back in time, so I don't have an answer. Mention me again to try once more.");
    }
    this.prune();
    const next = Math.min(...this.ids().map((id) => this.load(id)?.expiresAt ?? Infinity));
    if (Number.isFinite(next)) this.deps.wakeIn(Math.max(next - Date.now(), 0) + 1000);
  }

  /** The ask a runner's `slack-<id>` is, if that machine is the one answering it. */
  forRun(runId: string, machine: string): Ask | null {
    if (!runId.startsWith(SLACK_PREFIX)) return null;
    const ask = this.load(runId);
    return ask?.machine === machine ? ask : null;
  }

  /** Whether an ask may have a read-only token for owner/repo: only its goal's, while it runs. */
  mayFetch(runId: string, machine: string, repo: string): boolean {
    const ask = this.forRun(runId, machine);
    const goal = ask ? this.store.goal(ask.goal) : null;
    return Boolean(ask && ask.state === "running" && ask.expiresAt > Date.now() && goal && goalMayFetch(goal, repo));
  }

  /** The goals a channel works on, less archived and deleted ones; with none of its picks left, every active goal and a note saying so. */
  channelGoals(channel: string): { goals: Goal[]; note: string | null } {
    const active = this.store.goals().filter((g) => !g.archived);
    const raw = this.store.get(`slack:channel:${channel}`);
    const picked: string[] = raw ? (JSON.parse(raw) as { goals: string[] }).goals : [ANY];
    if (picked.includes(ANY)) return { goals: active, note: null };
    const goals = active.filter((g) => picked.includes(g.id));
    return goals.length ? { goals, note: null } : { goals: active, note: ARCHIVED_NOTE };
  }

  /** The channels Maple has been asked to pick goals in. */
  channels(): string[] {
    return JSON.parse(this.store.get("slack:channels") ?? "[]");
  }

  /** Whether Slack's event `id` came before (a retry); remembers the latest few hundred. */
  seen(id: string): boolean {
    const ids: string[] = JSON.parse(this.store.get("slack:events") ?? "[]");
    if (ids.includes(id)) return true;
    this.store.set("slack:events", JSON.stringify([...ids, id].slice(-300)));
    return false;
  }

  /** Posts in a thread, or notes why it couldn't. */
  private async post(channel: string, threadTs: string, said: string, blocks?: Blocks): Promise<string | null> {
    const token = await this.deps.token();
    if (!token) return null;
    return postMessage(token, channel, threadTs, said, blocks).catch((e) => (this.deps.problem((e as Error).message), null));
  }

  private async update(channel: string, ts: string, said: string, blocks?: Blocks) {
    const token = await this.deps.token();
    if (token) await updateMessage(token, channel, ts, said, blocks).catch((e) => this.deps.problem((e as Error).message));
  }

  /** Maple joined a channel (a message of its own), or someone mentioned it with `goals` (a reply in their thread, if they're in one): asks which goals the channel works on. */
  async picker(channel: string, threadTs?: string) {
    const active = this.store.goals().filter((g) => !g.archived);
    const options = [{ text: { type: "plain_text", text: "Any goal" }, value: ANY }, ...active.slice(0, 99).map((g) => ({ text: { type: "plain_text", text: g.name.slice(0, 75) }, value: g.id }))];
    const blocks: Blocks = [
      {
        type: "section",
        text: { type: "mrkdwn", text: "Which goals should I work on here? I'll answer from their code and propose tasks in them." },
        accessory: { type: "multi_static_select", action_id: "goals.pick", placeholder: { type: "plain_text", text: "Pick goals" }, options },
      },
    ];
    const token = await this.deps.token();
    if (!token) return;
    await postMessage(token, channel, threadTs ?? null, "Which goals should I work on here?", blocks).catch(async (e) => {
      const why = (e as Error).message;
      this.deps.problem(why);
      if (threadTs) await this.post(channel, threadTs, `I couldn't show the goal picker here: ${why}`);
    });
    const channels = this.channels();
    if (!channels.includes(channel)) this.store.set("slack:channels", JSON.stringify([...channels, channel]));
  }

  /** A mention: its channel's best goal is read by an agent on an online machine, which answers the thread. */
  async ask(input: SlackAsk) {
    this.store.set("slack:lastMention", String(Date.now()));
    const { goals, note } = this.channelGoals(input.channel);
    if (!goals.length) return void (await this.post(input.channel, input.threadTs, "This factory has no goals yet, so there's no code for me to look at."));
    const login = input.login ?? null;
    if (wantsMine(input.question)) {
      // From the factory's state, for the linked member alone; no agent.
      const said = login ? mineSummary(this.store.tasks(), this.store.goals(), login, Date.now()) : LINK_HINT;
      return void (await this.post(input.channel, input.threadTs, said.slice(0, 3000), sections(said)));
    }
    const work = workSummary(this.store.tasks(), this.store.queued(), goals, Date.now());
    if (wantsStatus(input.question)) {
      // Answered from the factory's own state: no agent, so no machine needs to be online.
      const said = note ? `${work}\n\n_${note}_` : work;
      return void (await this.post(input.channel, input.threadTs, said.slice(0, 3000), sections(said)));
    }
    const asked = words(`${input.question} ${input.thread.map((l) => l.text).join(" ")}`);
    const score = (g: Goal) => [...words(`${g.name} ${g.summary}`)].filter((w) => asked.has(w)).length;
    const goal = goals.reduce((best, g) => (score(g) > score(best) ? g : best), goals[0]);
    const machines = (await this.deps.machines()).filter((m) => m.online && !this.deps.paused(m)).sort((a, b) => a.sessions.length - b.sessions.length);
    const agent = ["claude", "codex"].find((a) => machines.some((m) => this.deps.hasAgent(m, a)));
    const machine = agent && machines.find((m) => this.deps.hasAgent(m, agent));
    if (!agent || !machine) return void (await this.post(input.channel, input.threadTs, "No machine is online to look into this right now (I answer with an agent on one of the factory's runners). Mention me again once one is. `@Maple status` still works: it says what's building and queued."));
    const replyTs = await this.post(input.channel, input.threadTs, "Looking into it…");
    if (!replyTs) return;
    const ask: Ask = {
      id: SLACK_PREFIX + crypto.randomUUID(), machine: machine.id, owner: machine.owner, agent, channel: input.channel, threadTs: input.threadTs, replyTs,
      requester: input.requester, login, question: input.question, thread: input.thread, attachments: input.attachments,
      goals: goals.map((g) => g.id), goal: goal.id, state: "running", proposal: null, answer: null, note, task: null, expiresAt: Date.now() + ASK_MS,
    };
    this.save(ask);
    this.deps.wakeIn(ASK_MS + 1000);
    const command: ServerToRunner = { type: "draft.run", id: ask.id, agent, prompt: askPrompt(ask, goal, goals, work, login ? mineSummary(this.store.tasks(), this.store.goals(), login, Date.now()) : null), repo: goal.folder ? null : goal.repo ?? null, folder: goal.folder ?? null, base: goal.base ?? null };
    if (!(await this.deps.toRunner(machine.id, command))) {
      ask.expiresAt = 0;
      this.save(ask);
      await this.update(ask.channel, replyTs, `I couldn't reach ${machine.name}. Mention me again in a moment.`);
    }
  }

  /** The agent's answer replaces "Looking into it…"; a proposed task comes with its buttons. */
  async done(runId: string, machine: string, output: string | null, error: string | null) {
    const ask = this.forRun(runId, machine);
    if (!ask || ask.state !== "running" || ask.expiresAt <= Date.now()) return;
    const goals = ask.goals.map((id) => this.store.goal(id)).filter((g): g is Goal => !!g && !g.archived);
    const parsed = output ? parseAnswer(output, goals) : null;
    if (!parsed) {
      ask.state = "answered";
      this.save(ask);
      return this.update(ask.channel, ask.replyTs, `I couldn't work that out${error ? ` (${error.slice(0, 200)})` : ""}. Try asking another way.`);
    }
    ask.state = "answered";
    ask.proposal = parsed.proposal;
    ask.answer = ask.note ? `${parsed.answer}\n\n_${ask.note}_` : parsed.answer;
    ask.expiresAt = Date.now() + ASK_MS;
    this.save(ask);
    this.deps.wakeIn(ASK_MS + 1000);
    const blocks = sections(ask.answer);
    if (ask.proposal) blocks.push(...card(ask, this.store.goal(ask.proposal.goal), null));
    await this.update(ask.channel, ask.replyTs, ask.answer.slice(0, 3000), blocks);
  }

  /** A click on one of Maple's messages. */
  async action(a: SlackAction) {
    if (a.action === "goals.pick") return this.picked(a);
    if (a.action !== "slack.create" && a.action !== "slack.dismiss") return;
    const ask = a.value ? this.load(a.value) : null;
    if (!ask || ask.channel !== a.channel.id) return;
    const goal = ask.proposal ? this.store.goal(ask.proposal.goal) : null;
    const answer = (footer: string) => this.update(ask.channel, ask.replyTs, (ask.answer ?? footer).slice(0, 3000), [...sections(ask.answer ?? ""), ...card(ask, goal, footer)]);
    if (ask.state === "created") return void (await this.post(ask.channel, ask.threadTs, `That's already ${ask.task}.`));
    if (ask.state === "dismissed") return void (await this.post(ask.channel, ask.threadTs, "That proposal was set aside. Mention me again to get a fresh one."));
    if (ask.state !== "answered" || !ask.proposal || ask.expiresAt <= Date.now()) {
      return void (await this.post(ask.channel, ask.threadTs, "That proposal expired. Mention me again to get a fresh one."));
    }
    if (a.action === "slack.dismiss") {
      ask.state = "dismissed";
      this.forget(ask);
      this.save(ask);
      return answer(`${a.user.name} said not now; no task made.`);
    }
    // Saved as created first, so a second click can't make it twice.
    ask.state = "created";
    this.save(ask);
    // Credited by login when the clicker linked their Slack account; the owner stays the answering machine's.
    const clicker = await this.deps.loginFor(a.team ?? "", a.user.id).catch(() => null);
    const by = clicker ? `@${clicker}` : a.user.name;
    let task: Task;
    try {
      task = await this.deps.make(ask, ask.proposal, by, a.channel.name, (made) => {
        ask.task = made.id;
        this.save(ask);
      });
    } catch (e) {
      if (ask.task) {
        // The task is made; only its planning didn't start. It stays created, so another click can't make a second.
        await answer(`Created ${ask.task} in ${goal?.name ?? "its goal"}`);
        return void (await this.post(ask.channel, ask.threadTs, `${ask.task} is made, but its planning didn't start: ${(e as Error).message} Send it to planning in the factory.`));
      }
      ask.state = "answered";
      this.save(ask);
      return void (await this.post(ask.channel, ask.threadTs, `I couldn't create it: ${(e as Error).message}`));
    }
    ask.task = task.id;
    this.save(ask);
    await answer(`Created ${task.id} in ${goal?.name ?? "its goal"} · planning`);
  }

  /** The picker's choice: saved for the channel, and the message says what it's set to. */
  private async picked(a: SlackAction) {
    const active = this.store.goals().filter((g) => !g.archived);
    const ids = a.selected.filter((v) => v === ANY || active.some((g) => g.id === v));
    if (!ids.length) return;
    this.store.set(`slack:channel:${a.channel.id}`, JSON.stringify({ goals: ids }));
    const names = ids.includes(ANY) ? "any goal" : ids.map((id) => active.find((g) => g.id === id)!.name).join(", ");
    if (a.messageTs) await this.update(a.channel.id, a.messageTs, `I'll work on ${names} here.`, [context(`I'll work on *${names}* here. Mention me with \`goals\` to change it.`)]);
  }
}

function askPrompt(ask: Ask, goal: Goal, goals: Goal[], work: string, mine: string | null): string {
  const thread = ask.thread.map((l) => `${l.author}: ${l.text.replace(/\n+/g, "\n  ")}`).join("\n");
  const list = goals.map((g) => `- ${g.id} · ${g.name}${g.summary ? `: ${g.summary.replace(/\s+/g, " ").slice(0, 300)}` : ""}`).join("\n");
  const files = ask.attachments.length ? `\n\nFiles posted in the thread (they'll be attached to a task if one is made):\n${ask.attachments.map((f) => `- ${f.name} (${f.mime})`).join("\n")}` : "";
  return `You're Maple, the software factory's assistant, answering a question in a Slack thread. You're in the code of the goal "${goal.name}"${goal.repos.length > 1 ? ` (${goal.repo}; it also spans ${goal.repos.slice(1).join(", ")})` : ""}, as it is on the base branch. You can only read; don't try to change anything.

<thread>
${thread}
</thread>

${ask.requester} asked: ${ask.question || "(see the thread)"}${files}${ask.login && mine ? `

The person asking is @${ask.login}, a member of this factory. Their own work right now:
<mine>
${mine}
</mine>
When they say "my", "mine" or "me", they mean @${ask.login}: answer from that block and the factory block.` : ""}

The goals this channel works on:
${list}

<factory>
${work}
</factory>
That's the factory's live work in these goals right now (tasks being built, queued in order, in review, in planning or waiting on a person). Answer questions about tasks, progress, the queue or reviews from that block, not the code, and cite task ids. You can't see anything about the work beyond it.

Answer questions about the code from the code: short, specific and friendly, in Slack's mrkdwn (*bold*, \`code\`, bullet lines; no headings or tables). Name the files where it helps.

If the thread asks for a change or describes a bug worth building, also propose one task in the best-suited of those goals. Don't propose one for a plain question.

Answer with only a JSON object:
{"answer": "<your reply>", "proposal": {"goal": "<a goal id from the list>", "title": "<an imperative title, under 70 characters>", "brief": "<Markdown: what's wrong or wanted, where in the code (files and functions), and what the change should do. No Done when section here.>", "doneWhen": ["<2–5 checks a builder could prove with a test, a command's output, a screenshot or a video>"]}}
Leave out "proposal" when there's no task to propose.`;
}
