// The factory's state, in OrgHub's own SQLite: goals, tasks (one JSON document each, shaped as
// the apps see them), the sessions working on them, and per-machine settings. One Durable Object
// owns it all, so every change is serialized without locks.

import type { Goal, MachineSettings, RiskAcceptance, RiskPolicy, Role, Task } from "../wire.ts";
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
  constructor(private sql: SqlStorage) {
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
    `);
  }

  // Goals

  goals(): Goal[] {
    return this.sql.exec<{ doc: string }>("SELECT doc FROM goals").toArray().map((r) => JSON.parse(r.doc));
  }

  goal(id: string): Goal | null {
    const row = this.sql.exec<{ doc: string }>("SELECT doc FROM goals WHERE id = ?", id).toArray()[0];
    return row ? JSON.parse(row.doc) : null;
  }

  saveGoal(goal: Goal) {
    this.sql.exec("INSERT INTO goals (id, doc) VALUES (?, ?) ON CONFLICT (id) DO UPDATE SET doc = excluded.doc", goal.id, JSON.stringify(goal));
  }

  // Tasks

  tasks(): Task[] {
    return this.sql.exec<{ doc: string }>("SELECT doc FROM tasks ORDER BY updated DESC").toArray().map((r) => JSON.parse(r.doc));
  }

  task(id: string): Task | null {
    const row = this.sql.exec<{ doc: string }>("SELECT doc FROM tasks WHERE id = ?", id).toArray()[0];
    return row ? JSON.parse(row.doc) : null;
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

  // Policy

  policy(): RiskPolicy {
    const saved = this.get("policy");
    return saved ? { ...DEFAULT_POLICY, ...JSON.parse(saved) } : DEFAULT_POLICY;
  }

  savePolicy(policy: RiskPolicy) {
    this.set("policy", JSON.stringify(policy));
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
