// The factory's state, in OrgHub's own SQLite: goals, tasks (one JSON document each, shaped as
// the apps see them), the sessions working on them, and per-machine settings. One Durable Object
// owns it all, so every change is serialized without locks.

import type { Goal, GoalFollow, IntakeRequest, MachineSettings, Note, OrgRepo, RiskAcceptance, RiskPolicy, Role, Task } from "../wire.ts";
import { DEFAULT_POLICY } from "./policy.ts";

/// What the server knows about a task that the apps don't need.
export interface TaskPrivate {
  /// The worktree on `task.machine`, as the runner reported it.
  worktree: string | null;
  /// The repo folder its worktree came from, on that machine.
  repoDir: string | null;
  base: string | null;
  /// The builder said it's done; finishing (commit and push) is under way.
  finishing: boolean;
  /// A merge was sent and hasn't been answered.
  merging?: boolean;
  /// Times the current role's session was restarted after an end that wasn't the agent's choice.
  restarts: number;
  /// The merge commit, once merged, and whether its worktree has been cleaned up since.
  mergedAs?: string | null;
  cleaned?: boolean;
  /// A hand-off (`task.handoff`) was sent and hasn't been answered; who asked for it.
  handingOff?: string | null;
  /// Where it was moved from, and the commit it carries on from, until its next session starts.
  movedFrom?: { machine: string; commit: string | null } | null;
  /** The repo its pull request is on, once the GitHub App pushed it, and its CI as GitHub reported it. */
  gh?: { owner: string; repo: string } | null;
  checks?: import("../github.ts").Check[];
  /** When its pull request was opened or found, so CI that never shows up stops being waited for. */
  prOpenedAt?: number;
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

export const DEFAULT_SETTINGS: MachineSettings = { capacity: null, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null };

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
      CREATE TABLE IF NOT EXISTS machine_settings (id TEXT PRIMARY KEY, doc TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS intake (id TEXT PRIMARY KEY, updated INTEGER NOT NULL, doc TEXT NOT NULL, reply_url TEXT);
      CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, owner TEXT NOT NULL, updated INTEGER NOT NULL, doc TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS notes_owner ON notes (owner, updated);
      CREATE TABLE IF NOT EXISTS goal_follows (login TEXT NOT NULL, goal TEXT NOT NULL, following INTEGER NOT NULL, PRIMARY KEY (login, goal));
    `);
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

  /** The org's repos (from the GitHub App, and added by hand), and when the app's were last read. */
  repos(): OrgRepo[] {
    return (JSON.parse(this.get("repos") ?? "[]") as (OrgRepo & { private?: boolean })[]).map(({ private: hidden, ...r }) => ({ ...r, isPrivate: r.isPrivate ?? hidden ?? false }));
  }

  saveRepos(repos: OrgRepo[]) {
    this.set("repos", JSON.stringify([...repos].sort((a, b) => a.name.localeCompare(b.name))));
    this.set("reposAt", String(Date.now()));
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
}

/** A stored goal, with fields added since it was saved. */
function goalDoc(doc: string): Goal {
  const goal = JSON.parse(doc) as Goal;
  return { ...goal, repos: goal.repos ?? (goal.repo ? [goal.repo] : []) };
}

/** A stored task, with fields added since it was saved. Tasks from before the queue keep their order. */
function taskDoc(doc: string): Task {
  const task = JSON.parse(doc) as Task;
  return { ...task, repo: task.repo ?? null, after: task.after ?? [], followUps: task.followUps ?? [], queueRank: task.queueRank ?? task.createdAt };
}

/** Front of the queue first; ties by age. */
export const byRank = (a: Task, b: Task) => a.queueRank! - b.queueRank! || a.createdAt - b.createdAt;

/** Whether its state calls for a session: planning, building (not finishing), or a review round in progress. */
export function needsSession(task: Task, priv: TaskPrivate): boolean {
  switch (task.state) {
    case "planning": return true;
    case "building": return !priv.finishing;
    case "reviewing": return task.autoReview?.rounds.at(-1)?.verdict === "inProgress";
    default: return false;
  }
}
