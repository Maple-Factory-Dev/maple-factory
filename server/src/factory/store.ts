// The factory's state, in OrgHub's own SQLite: goals, tasks (one JSON document each, shaped as
// the apps see them), the sessions working on them, and per-machine settings. One Durable Object
// owns it all, so every change is serialized without locks.

import type { Goal, GoalFollow, GoalTally, IntakeRequest, MachineSettings, McpConnector, Note, OrgRepo, PromptAdditions, RepoWorktreeScripts, RiskAcceptance, RiskPolicy, Role, Task, WorktreeScripts } from "../wire.ts";
import { DEFAULT_POLICY } from "./policy.ts";
import { inferEvents, type StatEvent } from "./stats.ts";

/// What the server knows about a task that the apps don't need.
export interface TaskPrivate {
  /// The worktree on `task.machine`, as the runner reported it.
  worktree: string | null;
  /// The repo folder its worktree came from, on that machine.
  repoDir: string | null;
  base: string | null;
  /// The builder said it's done; finishing (commit and push) is under way.
  finishing: boolean;
  /** Finishes in a row the repo's checks stopped, since its last push (or its last hand about them). */
  checkFailures?: number;
  /// A merge was sent and hasn't been answered.
  merging?: boolean;
  /** When that merge was sent, so one that never answers is noticed (none on a merge from before this was kept). */
  mergeStartedAt?: number | null;
  /** That merge is waiting in GitHub's merge queue (the base branch requires one), not a merge call. */
  queued?: boolean;
  /// Who started the last merge ("factory" for an auto-merge), for its stats.
  mergeBy?: string | null;
  /** The head it was last noted as waiting for a person to merge (autoMerges off), so it's said once per head. */
  pendingMerge?: string | null;
  /** The head a person held the auto-merge on (task.holdMerge), so its countdown doesn't start again. */
  mergeHeld?: string | null;
  /** The head the auto-merge countdown (task.mergeAt) started for. */
  mergeHead?: string | null;
  /** Times the factory sent it back to fix a merge on its own (autoFixMerges). */
  mergeFixes?: number;
  /** A dry-run merge (`task.merge_check`) waiting for its answer: the head it checks, the task whose
   *  merge prompted it (none: the check before its own auto-merge), and when it was sent. */
  mergeCheck?: { head: string | null; since: string | null; at: number } | null;
  /** The head the last pre-merge check answered for, so its auto-merge goes ahead. */
  mergeChecked?: string | null;
  /// Times the current role's session was restarted after an end that wasn't the agent's choice.
  restarts: number;
  /// The merge commit, once merged, and whether its worktree has been cleaned up since.
  mergedAs?: string | null;
  cleaned?: boolean;
  /** What became of its branch on origin after the factory merged it: unknown (unset) or failed gets a retry at cleanup. */
  remoteBranch?: "deleted" | "kept" | "failed" | null;
  /// A hand-off (`task.handoff`) was sent and hasn't been answered; who asked for it.
  handingOff?: string | null;
  /// Where it was moved from, and the commit it carries on from, until its next session starts.
  movedFrom?: { machine: string; commit: string | null } | null;
  /** The repo its pull request is on, once the GitHub App pushed it, and its CI as GitHub reported it. */
  gh?: { owner: string; repo: string } | null;
  checks?: import("../github.ts").Check[];
  /** When its pull request was opened or found, so CI that never shows up stops being waited for. */
  prOpenedAt?: number;
  /** What it had used when a person last gave it more budget (an overBudget budget hand answered with anything
   *  but Cancel); its next limit is one budget on from there. */
  budgetBase?: import("./policy.ts").BudgetBase | null;
  /** When the factory typed the over-budget nudge into its session; a hand still missing 10 minutes on is raised for it. */
  budgetAskedAt?: number | null;
  /** Cancelled with its goal's archive, to have its worktree removed (when nothing would be lost). */
  discard?: boolean;
}

export interface TaskSession {
  id: string;
  task: string;
  role: Role;
  machine: string;
  agent: string;
  started: number;
  ended: number | null;
  cause: string | null;
  /// A team slot on someone else's machine, or the owner's own.
  kind: "personal" | "team";
}

/// What one factory session has spent, as its runner last measured it.
export interface SessionCostRow {
  session: string;
  task: string;
  goal: string;
  role: Role;
  agent: string;
  model: string | null;
  /// Claude Code's API-equivalent estimate; null where the agent gives none (Codex).
  costUsd: number | null;
  tokens: { input: number; output: number; cacheRead: number; cacheWrite: number };
  updated: number;
}

export const DEFAULT_SETTINGS: MachineSettings = { capacity: null, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null };

/** How far back the snapshot sends finished tasks. */
export const SNAPSHOT_WINDOW_MS = 14 * 24 * 3_600_000;
const FINISHED_SQL = "'merged', 'cancelled', 'closed'";

export class Store {
  private sql: SqlStorage;

  // Not a parameter property, so node's type stripping can load it for test/queue.test.ts.
  constructor(sql: SqlStorage) {
    this.sql = sql;
    sql.exec(`
      CREATE TABLE IF NOT EXISTS goals (id TEXT PRIMARY KEY, doc TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS tasks (
        id TEXT PRIMARY KEY, goal TEXT NOT NULL, state TEXT NOT NULL, owner TEXT NOT NULL,
        updated INTEGER NOT NULL, doc TEXT NOT NULL, private TEXT NOT NULL DEFAULT '{}'
      );
      CREATE TABLE IF NOT EXISTS counters (prefix TEXT PRIMARY KEY, n INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY, task TEXT NOT NULL, role TEXT NOT NULL, machine TEXT NOT NULL, agent TEXT NOT NULL,
        started INTEGER NOT NULL, ended INTEGER, cause TEXT, kind TEXT NOT NULL DEFAULT 'personal'
      );
      CREATE INDEX IF NOT EXISTS sessions_task ON sessions (task);
      CREATE INDEX IF NOT EXISTS tasks_goal_updated ON tasks (goal, updated);
      CREATE TABLE IF NOT EXISTS machine_settings (id TEXT PRIMARY KEY, doc TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS intake (id TEXT PRIMARY KEY, updated INTEGER NOT NULL, doc TEXT NOT NULL, reply_url TEXT);
      CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, owner TEXT NOT NULL, updated INTEGER NOT NULL, doc TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS notes_owner ON notes (owner, updated);
      CREATE TABLE IF NOT EXISTS goal_follows (login TEXT NOT NULL, goal TEXT NOT NULL, following INTEGER NOT NULL, PRIMARY KEY (login, goal));
      CREATE TABLE IF NOT EXISTS stats_events (
        id TEXT PRIMARY KEY, at INTEGER NOT NULL, kind TEXT NOT NULL, task TEXT NOT NULL, goal TEXT NOT NULL,
        role TEXT, actor TEXT, detail TEXT NOT NULL DEFAULT '{}'
      );
      CREATE INDEX IF NOT EXISTS stats_events_at ON stats_events (at);
      CREATE TABLE IF NOT EXISTS session_costs (
        session TEXT PRIMARY KEY, task TEXT NOT NULL, goal TEXT NOT NULL, role TEXT NOT NULL, agent TEXT NOT NULL,
        model TEXT, cost_usd REAL, tokens TEXT NOT NULL DEFAULT '{}', updated INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS session_costs_updated ON session_costs (updated);
      CREATE TABLE IF NOT EXISTS repo_scripts (repo TEXT PRIMARY KEY, doc TEXT NOT NULL, updated_by TEXT NOT NULL, updated_at INTEGER NOT NULL);
    `);
    // A repo's prompt additions came later: added once, to a table made before them.
    if (!this.sql.exec<{ name: string }>("PRAGMA table_info(repo_scripts)").toArray().some((c) => c.name === "prompts")) {
      this.sql.exec("ALTER TABLE repo_scripts ADD COLUMN prompts TEXT");
    }
    this.backfillStats();
  }

  // Statistics: an append-only log of touchpoints (stats.ts adds them up).

  recordStat(e: Omit<StatEvent, "id">) {
    this.sql.exec(
      "INSERT INTO stats_events (id, at, kind, task, goal, role, actor, detail) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      crypto.randomUUID(), e.at, e.kind, e.task, e.goal, e.role, e.actor, JSON.stringify(e.detail),
    );
  }

  statEvents(since = 0): StatEvent[] {
    return this.statRows("SELECT * FROM stats_events WHERE at >= ? ORDER BY at", since);
  }

  /** The review rounds `tasks` had before `before`: a merge's earlier rounds, for review rounds per merge. */
  statRoundsBefore(tasks: string[], before: number): StatEvent[] {
    if (!tasks.length) return [];
    return this.statRows(
      "SELECT * FROM stats_events WHERE kind = 'review.round' AND at < ? AND task IN (SELECT value FROM json_each(?)) ORDER BY at",
      before, JSON.stringify(tasks),
    );
  }

  private statRows(query: string, ...args: (string | number)[]): StatEvent[] {
    return this.sql.exec<{ id: string; at: number; kind: string; task: string; goal: string; role: string | null; actor: string | null; detail: string }>(query, ...args)
      .toArray().map((r) => ({ ...r, kind: r.kind as StatEvent["kind"], detail: JSON.parse(r.detail) }));
  }

  /** Once: the history tasks from before `stats_events` show, worked out from their documents. */
  private backfillStats() {
    if (this.get("stats:backfilled")) return;
    for (const task of this.tasks()) for (const e of inferEvents(task)) this.recordStat(e);
    this.set("stats:backfilled", String(Date.now()));
  }

  // Costs: one row per factory session, its highest totals so far.

  /** Keeps the higher of each total, so a restarted status line (counting from zero again) can't lower them. */
  recordSessionCost(c: SessionCostRow) {
    const old = this.sql.exec<{ cost_usd: number | null; tokens: string; model: string | null }>(
      "SELECT cost_usd, tokens, model FROM session_costs WHERE session = ?", c.session,
    ).toArray()[0];
    let { costUsd, tokens, model } = c;
    if (old) {
      const prev = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, ...JSON.parse(old.tokens) } as SessionCostRow["tokens"];
      costUsd = costUsd == null ? old.cost_usd : old.cost_usd == null ? costUsd : Math.max(costUsd, old.cost_usd);
      tokens = {
        input: Math.max(tokens.input, prev.input),
        output: Math.max(tokens.output, prev.output),
        cacheRead: Math.max(tokens.cacheRead, prev.cacheRead),
        cacheWrite: Math.max(tokens.cacheWrite, prev.cacheWrite),
      };
      model = model ?? old.model;
    }
    this.sql.exec(
      `INSERT INTO session_costs (session, task, goal, role, agent, model, cost_usd, tokens, updated) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (session) DO UPDATE SET model = excluded.model, cost_usd = excluded.cost_usd, tokens = excluded.tokens, updated = excluded.updated`,
      c.session, c.task, c.goal, c.role, c.agent, model, costUsd, JSON.stringify(tokens), c.updated,
    );
  }

  /** Sessions that spent anything since `since` (ms), on `goal`'s tasks when given. */
  sessionCosts(since = 0, goal?: string | null): SessionCostRow[] {
    const rows = goal
      ? this.sql.exec("SELECT * FROM session_costs WHERE updated >= ? AND goal = ?", since, goal)
      : this.sql.exec("SELECT * FROM session_costs WHERE updated >= ?", since);
    return (rows.toArray() as { session: string; task: string; goal: string; role: string; agent: string; model: string | null; cost_usd: number | null; tokens: string; updated: number }[])
      .map((r) => ({
        session: r.session, task: r.task, goal: r.goal, role: r.role as Role, agent: r.agent, model: r.model, costUsd: r.cost_usd,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, ...JSON.parse(r.tokens) }, updated: r.updated,
      }));
  }

  /** A task's sessions' spend: what its cost budget adds up. */
  taskCosts(task: string): { session: string; costUsd: number | null }[] {
    return this.sql.exec<{ session: string; cost_usd: number | null }>("SELECT session, cost_usd FROM session_costs WHERE task = ?", task)
      .toArray().map((r) => ({ session: r.session, costUsd: r.cost_usd }));
  }

  // Goals

  goals(): Goal[] {
    return this.sql.exec<{ doc: string }>("SELECT doc FROM goals").toArray().map((r) => goalDoc(r.doc));
  }

  goal(id: string): Goal | null {
    const row = this.sql.exec<{ doc: string }>("SELECT doc FROM goals WHERE id = ?", id).toArray()[0];
    return row ? goalDoc(row.doc) : null;
  }

  saveGoal(goal: Goal) {
    this.sql.exec("INSERT INTO goals (id, doc) VALUES (?, ?) ON CONFLICT (id) DO UPDATE SET doc = excluded.doc", goal.id, JSON.stringify(goal));
  }

  // Tasks

  tasks(): Task[] {
    return this.sql.exec<{ doc: string }>("SELECT doc FROM tasks ORDER BY updated DESC").toArray().map((r) => taskDoc(r.doc));
  }

  /**
   * What the apps' snapshot holds: every unfinished task, and finished ones updated in the last
   * SNAPSHOT_WINDOW_MS. Sending every task ever made outgrew a WebSocket message (MF-212).
   */
  snapshotTasks(now = Date.now()): { tasks: Task[]; left: number } {
    const since = now - SNAPSHOT_WINDOW_MS;
    const tasks = this.sql
      .exec<{ doc: string }>(`SELECT doc FROM tasks WHERE state NOT IN (${FINISHED_SQL}) OR updated >= ? ORDER BY updated DESC`, since)
      .toArray()
      .map((r) => taskDoc(r.doc));
    const left = this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM tasks WHERE state IN (${FINISHED_SQL}) AND updated < ?`, since).one().n;
    return { tasks, left };
  }

  /**
   * Finished tasks updated before `before` (or at it, with an ID before `beforeId`), newest first:
   * the ones the snapshot leaves out, a page at a time. No `before`: the snapshot's window start.
   */
  olderTasks(goal: string | null, before: number | null, beforeId: string | null, limit: number | null, now = Date.now()): { tasks: Task[]; more: boolean } {
    const n = Math.min(Math.max(Math.floor(limit ?? 50), 1), 200);
    const at = before ?? now - SNAPSHOT_WINDOW_MS;
    const where = [`state IN (${FINISHED_SQL})`, beforeId != null ? "(updated < ? OR (updated = ? AND id < ?))" : "updated < ?"];
    const args: (string | number)[] = beforeId != null ? [at, at, beforeId] : [at];
    if (goal != null) {
      where.push("goal = ?");
      args.push(goal);
    }
    const rows = this.sql
      .exec<{ doc: string }>(`SELECT doc FROM tasks WHERE ${where.join(" AND ")} ORDER BY updated DESC, id DESC LIMIT ?`, ...args, n + 1)
      .toArray();
    return { tasks: rows.slice(0, n).map((r) => taskDoc(r.doc)), more: rows.length > n };
  }

  /** Each goal's task counts over every task, for progress the snapshot alone can't show. */
  tallies(): GoalTally[] {
    const byGoal = new Map<string, GoalTally>();
    for (const r of this.sql.exec<{ goal: string; state: string; n: number }>("SELECT goal, state, COUNT(*) AS n FROM tasks GROUP BY goal, state").toArray()) {
      const t = byGoal.get(r.goal) ?? { goal: r.goal, merged: 0, cancelled: 0, closed: 0, total: 0 };
      if (r.state === "merged" || r.state === "cancelled" || r.state === "closed") t[r.state] += r.n;
      t.total += r.n;
      byGoal.set(r.goal, t);
    }
    return [...byGoal.values()].sort((a, b) => a.goal.localeCompare(b.goal));
  }

  /** Tasks whose next session hasn't started (to plan, build or review), front of the queue first. */
  queued(): Task[] {
    return this.tasks()
      .filter((t) => !t.worker && !t.hand && !t.question && needsSession(t, this.private(t.id)))
      .sort(byRank);
  }

  /** The rank that puts a task just ahead of `before` (the back, when none), among `queue` without it. */
  rankBefore(id: string, before: Task | null, queue = this.queued()): number {
    const rest = queue.filter((t) => t.id !== id);
    if (!before) return rest.length ? Math.max(...rest.map((t) => t.queueRank!)) + 1 : Date.now();
    const at = rest.findIndex((t) => t.id === before.id);
    const prev = at > 0 ? rest[at - 1] : null;
    return prev ? (prev.queueRank! + before.queueRank!) / 2 : before.queueRank! - 1000;
  }

  /** A goal's drafts, first first. */
  drafts(goal: string): Task[] {
    return this.tasks()
      .filter((t) => t.goal === goal && t.state === "drafting")
      .sort(byDraftRank);
  }

  /** The draftRank that puts a draft just ahead of `before` (the bottom, when none), among `drafts` without it. */
  draftRankBefore(id: string, before: Task | null, drafts: Task[]): number {
    const rest = drafts.filter((t) => t.id !== id);
    if (!before) return rest.length ? Math.max(...rest.map((t) => t.draftRank!)) + 1 : Date.now();
    const at = rest.findIndex((t) => t.id === before.id);
    const prev = at > 0 ? rest[at - 1] : null;
    return prev ? (prev.draftRank! + before.draftRank!) / 2 : before.draftRank! - 1000;
  }

  task(id: string): Task | null {
    const row = this.sql.exec<{ doc: string }>("SELECT doc FROM tasks WHERE id = ?", id).toArray()[0];
    return row ? taskDoc(row.doc) : null;
  }

  private(id: string): TaskPrivate {
    const row = this.sql.exec<{ private: string }>("SELECT private FROM tasks WHERE id = ?", id).toArray()[0];
    return { worktree: null, repoDir: null, base: null, finishing: false, restarts: 0, ...(row ? JSON.parse(row.private) : {}) };
  }

  saveTask(task: Task, priv?: TaskPrivate) {
    this.sql.exec(
      `INSERT INTO tasks (id, goal, state, owner, updated, doc, private) VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET goal = excluded.goal, state = excluded.state, owner = excluded.owner,
         updated = excluded.updated, doc = excluded.doc${priv ? ", private = excluded.private" : ""}`,
      task.id, task.goal, task.state, task.owner, task.updatedAt, JSON.stringify(task), JSON.stringify(priv ?? {}),
    );
  }

  savePrivate(id: string, priv: TaskPrivate) {
    this.sql.exec("UPDATE tasks SET private = ? WHERE id = ?", JSON.stringify(priv), id);
  }

  /// ATL-1, ATL-2…: per goal prefix, never reused.
  nextId(prefix: string): string {
    const row = this.sql.exec<{ n: number }>(
      "INSERT INTO counters (prefix, n) VALUES (?, 1) ON CONFLICT (prefix) DO UPDATE SET n = n + 1 RETURNING n", prefix,
    ).one();
    return `${prefix}-${row.n}`;
  }

  // Sessions

  addSession(s: TaskSession) {
    this.sql.exec(
      "INSERT INTO sessions (id, task, role, machine, agent, started, kind) VALUES (?, ?, ?, ?, ?, ?, ?)",
      s.id, s.task, s.role, s.machine, s.agent, s.started, s.kind,
    );
  }

  session(id: string): TaskSession | null {
    return (this.sql.exec("SELECT * FROM sessions WHERE id = ?", id).toArray()[0] as unknown as TaskSession | undefined) ?? null;
  }

  endSession(id: string, cause: string) {
    this.sql.exec("UPDATE sessions SET ended = ?, cause = ? WHERE id = ? AND ended IS NULL", Date.now(), cause, id);
  }

  /** Agent time per task since `since` (ms), with each task's goal: what "where it went" adds up. */
  sessionTime(since: number): { goal: string; task: string; ms: number }[] {
    const now = Date.now();
    return this.sql.exec<{ goal: string; task: string; ms: number }>(
      `SELECT t.goal AS goal, s.task AS task, SUM(MIN(COALESCE(s.ended, ?), ?) - MAX(s.started, ?)) AS ms
       FROM sessions s JOIN tasks t ON t.id = s.task
       WHERE COALESCE(s.ended, ?) > ? GROUP BY t.goal, s.task`,
      now, now, since, now, since,
    ).toArray();
  }

  /** Every session a task has had, ended or running: what its time budget adds up. */
  taskSessions(task: string): TaskSession[] {
    return this.sql.exec("SELECT * FROM sessions WHERE task = ?", task).toArray() as unknown as TaskSession[];
  }

  /** Local dev only (/dev/age-sessions): moves a task's sessions `ms` into the past. */
  ageSessions(task: string, ms: number) {
    this.sql.exec("UPDATE sessions SET started = started - ?, ended = ended - ? WHERE task = ?", ms, ms, task);
  }

  liveSessions(): TaskSession[] {
    return this.sql.exec("SELECT * FROM sessions WHERE ended IS NULL").toArray() as unknown as TaskSession[];
  }

  // Machines

  /** A machine's settings; a pause whose time is up reads as resumed. */
  settings(machine: string): MachineSettings {
    const row = this.sql.exec<{ doc: string }>("SELECT doc FROM machine_settings WHERE id = ?", machine).toArray()[0];
    const s: MachineSettings = { ...DEFAULT_SETTINGS, ...(row ? JSON.parse(row.doc) : {}) };
    // Pauses from before pausedUntil was a field were objects.
    if (typeof s.paused !== "boolean") s.paused = Boolean(s.paused);
    if (s.paused && s.pausedUntil != null && s.pausedUntil <= Date.now()) return { ...s, paused: false, pausedUntil: null };
    return s;
  }

  saveSettings(machine: string, settings: MachineSettings) {
    this.sql.exec(
      "INSERT INTO machine_settings (id, doc) VALUES (?, ?) ON CONFLICT (id) DO UPDATE SET doc = excluded.doc",
      machine, JSON.stringify(settings),
    );
  }

  // Intake

  intake(): IntakeRequest[] {
    return this.sql.exec<{ doc: string }>("SELECT doc FROM intake ORDER BY updated DESC LIMIT 200").toArray().map((r) => JSON.parse(r.doc));
  }

  intakeRequest(id: string): IntakeRequest | null {
    const row = this.sql.exec<{ doc: string }>("SELECT doc FROM intake WHERE id = ?", id).toArray()[0];
    return row ? JSON.parse(row.doc) : null;
  }

  /** `replyUrl` undefined keeps the one it has. */
  saveIntake(request: IntakeRequest, replyUrl?: string | null) {
    this.sql.exec(
      `INSERT INTO intake (id, updated, doc, reply_url) VALUES (?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET updated = excluded.updated, doc = excluded.doc${replyUrl === undefined ? "" : ", reply_url = excluded.reply_url"}`,
      request.id, Date.now(), JSON.stringify(request), replyUrl ?? null,
    );
  }

  /** The request whose replies go to `replyUrl` (an issue's), if there is one. */
  intakeByReplyUrl(replyUrl: string): string | null {
    return this.sql.exec<{ id: string }>("SELECT id FROM intake WHERE reply_url = ? ORDER BY updated DESC LIMIT 1", replyUrl).toArray()[0]?.id ?? null;
  }

  intakeReplyUrl(id: string): string | null {
    return this.sql.exec<{ reply_url: string | null }>("SELECT reply_url FROM intake WHERE id = ?", id).toArray()[0]?.reply_url ?? null;
  }

  // Notes

  notes(owner: string): Note[] {
    return this.sql.exec<{ doc: string }>("SELECT doc FROM notes WHERE owner = ? ORDER BY updated DESC", owner).toArray().map((r) => JSON.parse(r.doc));
  }

  note(id: string): Note | null {
    const row = this.sql.exec<{ doc: string }>("SELECT doc FROM notes WHERE id = ?", id).toArray()[0];
    return row ? JSON.parse(row.doc) : null;
  }

  saveNote(note: Note) {
    this.sql.exec(
      "INSERT INTO notes (id, owner, updated, doc) VALUES (?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET updated = excluded.updated, doc = excluded.doc",
      note.id, note.owner, note.updatedAt, JSON.stringify(note),
    );
  }

  deleteNote(id: string) {
    this.sql.exec("DELETE FROM notes WHERE id = ?", id);
  }

  // Follows: only what people chose; the apps work out the rest (goals they lead, work in, or are on the team for).

  follows(login: string): GoalFollow[] {
    return this.sql.exec<{ goal: string; following: number }>("SELECT goal, following FROM goal_follows WHERE login = ?", login).toArray()
      .map((r) => ({ goal: r.goal, following: r.following === 1 }));
  }

  setFollow(login: string, goal: string, following: boolean) {
    this.sql.exec(
      "INSERT INTO goal_follows (login, goal, following) VALUES (?, ?, ?) ON CONFLICT (login, goal) DO UPDATE SET following = excluded.following",
      login, goal, following ? 1 : 0,
    );
  }

  // Policy

  policy(): RiskPolicy {
    const saved = this.get("policy");
    return saved ? { ...DEFAULT_POLICY, ...JSON.parse(saved) } : DEFAULT_POLICY;
  }

  savePolicy(policy: RiskPolicy) {
    this.set("policy", JSON.stringify(policy));
  }

  /** The org's additions to every session's prompt, by role. */
  prompts(): PromptAdditions {
    const saved = this.get("prompts");
    return { planner: "", builder: "", reviewer: "", ...(saved ? JSON.parse(saved) : {}) };
  }

  savePrompts(prompts: PromptAdditions) {
    this.set("prompts", JSON.stringify(prompts));
  }

  /** The factory's icon: its id in the bucket (icon/<id>), if it has one. */
  icon(): string | null {
    return this.get("icon");
  }

  /** None removes it. */
  saveIcon(id: string | null) {
    if (id) this.set("icon", id);
    else this.sql.exec("DELETE FROM kv WHERE key = 'icon'");
  }

  /** The factory's display name, set by an admin, if it has one (the apps fall back to the GitHub org). */
  name(): string | null {
    return this.get("name");
  }

  /** None clears it. */
  saveName(name: string | null) {
    if (name) this.set("name", name);
    else this.sql.exec("DELETE FROM kv WHERE key = 'name'");
  }

  /** Other GitHub accounts an admin approved: the app's installations on them add repos too. */
  repoOwners(): string[] {
    return JSON.parse(this.get("repoOwners") ?? "[]");
  }

  saveRepoOwners(owners: string[]) {
    this.set("repoOwners", JSON.stringify(owners));
  }

  /** The factory's MCP connectors, secrets included: only for runners (apps get `redacted`). */
  connectors(): McpConnector[] {
    return JSON.parse(this.get("connectors") ?? "[]");
  }

  saveConnectors(connectors: McpConnector[]) {
    this.set("connectors", JSON.stringify(connectors));
  }

  /** The org's repos (from the GitHub App, and added by hand), and when the app's were last read. */
  repos(): OrgRepo[] {
    return (JSON.parse(this.get("repos") ?? "[]") as (OrgRepo & { private?: boolean })[]).map(({ private: hidden, ...r }) => ({ ...r, isPrivate: r.isPrivate ?? hidden ?? false }));
  }

  saveRepos(repos: OrgRepo[]) {
    this.set("repos", JSON.stringify([...repos].sort((a, b) => a.name.localeCompare(b.name))));
    this.set("reposAt", String(Date.now()));
  }

  /** Every repo's worktree scripts and prompt additions, by repo name. */
  repoScripts(): RepoWorktreeScripts[] {
    return this.sql.exec<{ repo: string; doc: string; prompts: string | null; updated_by: string; updated_at: number }>("SELECT * FROM repo_scripts ORDER BY repo")
      .toArray().map((r) => ({ repo: r.repo, scripts: JSON.parse(r.doc), prompts: r.prompts ? JSON.parse(r.prompts) : null, updatedBy: r.updated_by, updatedAt: r.updated_at }));
  }

  /** One repo's row (its name in any case), if it has scripts or prompts. */
  repoSetup(repo: string | null | undefined): RepoWorktreeScripts | null {
    return repo ? this.repoScripts().find((r) => r.repo.toLowerCase() === repo.toLowerCase()) ?? null : null;
  }

  /** One repo's prompt additions, if it has any. */
  repoPrompts(repo: string | null | undefined): PromptAdditions | null {
    if (!repo) return null;
    const row = this.sql.exec<{ prompts: string | null }>("SELECT prompts FROM repo_scripts WHERE repo = ? COLLATE NOCASE", repo).toArray()[0];
    return row?.prompts ? JSON.parse(row.prompts) : null;
  }

  /** One repo's worktree scripts (its name in any case), if it has any. */
  scriptsFor(repo: string | null | undefined): WorktreeScripts | null {
    if (!repo) return null;
    const row = this.sql.exec<{ doc: string }>("SELECT doc FROM repo_scripts WHERE repo = ? COLLATE NOCASE", repo).toArray()[0];
    // A row with only prompt additions has no scripts.
    return row && row.doc !== "{}" ? JSON.parse(row.doc) : null;
  }

  /** Both none removes the row. */
  saveRepoScripts(repo: string, scripts: WorktreeScripts | null, by: string, prompts: PromptAdditions | null = null) {
    this.sql.exec("DELETE FROM repo_scripts WHERE repo = ? COLLATE NOCASE", repo);
    if (scripts || prompts) {
      this.sql.exec("INSERT INTO repo_scripts (repo, doc, prompts, updated_by, updated_at) VALUES (?, ?, ?, ?, ?)", repo, JSON.stringify(scripts ?? {}), prompts ? JSON.stringify(prompts) : null, by, Date.now());
    }
  }

  reposAt(): number {
    return Number(this.get("reposAt") ?? 0);
  }

  acceptances(): RiskAcceptance[] {
    return JSON.parse(this.get("acceptances") ?? "[]");
  }

  saveAcceptances(list: RiskAcceptance[]) {
    this.set("acceptances", JSON.stringify(list));
  }

  get(key: string): string | null {
    return this.sql.exec<{ value: string }>("SELECT value FROM kv WHERE key = ?", key).toArray()[0]?.value ?? null;
  }

  set(key: string, value: string) {
    this.sql.exec("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", key, value);
  }

  delete(key: string) {
    this.sql.exec("DELETE FROM kv WHERE key = ?", key);
  }
}

/** A stored goal, with fields added since it was saved. */
function goalDoc(doc: string): Goal {
  const goal = JSON.parse(doc) as Goal;
  return { ...goal, repos: goal.repos ?? (goal.repo ? [goal.repo] : []) };
}

/** A stored task, with fields added since it was saved. Tasks from before the queue keep their order. */
function taskDoc(doc: string): Task {
  const task = JSON.parse(doc) as Task;
  return { ...task, model: task.model ?? null, repo: task.repo ?? null, after: task.after ?? [], followUps: task.followUps ?? [], artifacts: task.artifacts ?? [], suggestedTitle: task.suggestedTitle ?? null, priority: task.priority ?? null, followUpOf: task.followUpOf ?? null, queueRank: task.queueRank ?? task.createdAt, draftRank: task.draftRank ?? task.createdAt };
}

/** Front of the queue first; ties by age. */
export const byRank = (a: Task, b: Task) => a.queueRank! - b.queueRank! || a.createdAt - b.createdAt;

/** First draft first; ties by age. */
export const byDraftRank = (a: Task, b: Task) => a.draftRank! - b.draftRank! || a.createdAt - b.createdAt;

/** Whether its state calls for a session: planning, building (not finishing), or a review round in progress. */
export function needsSession(task: Task, priv: TaskPrivate): boolean {
  switch (task.state) {
    case "planning": return true;
    case "building": return !priv.finishing;
    case "reviewing": return task.autoReview?.rounds.at(-1)?.verdict === "inProgress";
    default: return false;
  }
}
