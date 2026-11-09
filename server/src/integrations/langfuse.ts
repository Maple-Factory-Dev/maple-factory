// Langfuse, the factory's first outbound integration: each task is one trace, each agent session's model,
// tokens and cost a generation on it, and the factory's touchpoints (plan versions, review rounds and
// their findings, hands, steers, how it merged) scores, so its eval signals sit next to its runs.
// Everything goes through Langfuse's public batch ingestion API in the background; a failure never
// holds the factory up, it only shows as the integration's last error.
//
// The mapping is pure (test/langfuse.test.ts); `LangfuseSink` is what the engine calls.

import type { IntegrationKind, Task } from "../wire.ts";
import type { StatKind } from "../factory/stats.ts";
import { LANGFUSE_DEFAULT_HOST } from "./registry.ts";

/** One event in an ingestion batch. Ids are stable, so a retry or a newer value upserts. */
export interface IngestionEvent {
  id: string;
  type: "trace-create" | "generation-create" | "score-create";
  timestamp: string;
  body: Record<string, unknown>;
}

/** What the trace needs from a task. */
export type TraceTask = Pick<Task, "id" | "title" | "repo" | "createdAt" | "agent"> & { goalName: string | null };

/** What a merge's score needs from the task: whether anyone ever asked for changes. */
export type MergeTask = Pick<Task, "changes"> & { autoReview?: { rounds: { verdict: string }[] } | null };

/** A session's cost row, as the engine keeps it. */
export interface SessionCost {
  session: string;
  role: string | null;
  agent: string;
  model: string | null;
  costUsd: number | null;
  tokens: { input: number; output: number; cacheRead: number; cacheWrite: number };
  updated: number;
}

const iso = (ms: number) => new Date(ms).toISOString();

/** A task's trace id: the same every time for the same task, 32 hex characters (a W3C trace id). */
export async function traceId(taskId: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`maple-factory\n${taskId}`));
  return [...new Uint8Array(digest).slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** The task's trace: named after its title, tagged with its goal and repo. An upsert, so a rename follows. */
export function traceEvent(trace: string, task: TraceTask, at: number): IngestionEvent {
  const tags = [task.goalName, task.repo].filter((t): t is string => !!t);
  return {
    id: `${trace}-trace-${at}`,
    type: "trace-create",
    timestamp: iso(at),
    body: { id: trace, timestamp: iso(task.createdAt), name: task.title, tags, metadata: { taskId: task.id, agent: task.agent, source: "maple-factory" } },
  };
}

/** A session's spend so far as a generation; its id is the session's, so each update replaces the last. */
export function generationEvent(trace: string, c: SessionCost): IngestionEvent {
  const usageDetails: Record<string, number> = { input: c.tokens.input, output: c.tokens.output };
  if (c.tokens.cacheRead) usageDetails.cache_read_input_tokens = c.tokens.cacheRead;
  if (c.tokens.cacheWrite) usageDetails.cache_creation_input_tokens = c.tokens.cacheWrite;
  return {
    id: `${c.session}-${c.updated}`,
    type: "generation-create",
    timestamp: iso(c.updated),
    body: {
      id: c.session,
      traceId: trace,
      name: c.role ?? "session",
      model: c.model ?? undefined,
      endTime: iso(c.updated),
      usageDetails,
      ...(c.costUsd != null ? { costDetails: { total: c.costUsd } } : {}),
      metadata: { agent: c.agent, role: c.role },
    },
  };
}

type ScoreValue = { dataType: "NUMERIC" | "BOOLEAN"; value: number } | { dataType: "CATEGORICAL"; value: string };

function score(trace: string, key: string, name: string, v: ScoreValue, at: number, comment?: string): IngestionEvent {
  const id = `${trace}-${key}`;
  return {
    id: `${id}-${at}`,
    type: "score-create",
    timestamp: iso(at),
    body: { id, traceId: trace, name, ...v, ...(comment ? { comment } : {}), environment: "default" },
  };
}

/** Merged with no review round asking for changes and no change requests from a person. */
export function mergedAsIs(task: MergeTask): boolean {
  return task.changes.length === 0 && !(task.autoReview?.rounds ?? []).some((r) => r.verdict === "changesRequested");
}

/**
 * A factory touchpoint as scores on its task's trace; none for the kinds Langfuse has no use for.
 * `task` is only read for a merge (was it as-is?).
 */
export function statEvents(trace: string, kind: StatKind, detail: Record<string, unknown>, at: number, task?: MergeTask): IngestionEvent[] {
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  switch (kind) {
    case "review.round": {
      const round = num(detail.number);
      const verdict = String(detail.verdict ?? "");
      if (!verdict || verdict === "inProgress") return [];
      return [
        score(trace, `review_verdict-r${round}`, "review_verdict", { dataType: "CATEGORICAL", value: verdict }, at, `Review round ${round}`),
        score(trace, `review_findings-r${round}`, "review_findings", { dataType: "NUMERIC", value: num(detail.found) }, at, `Review round ${round}${detail.fixed != null ? `, ${num(detail.fixed)} fixed` : ""}`),
      ];
    }
    case "plan.approved":
      return [score(trace, "plan_versions", "plan_versions", { dataType: "NUMERIC", value: num(detail.version) }, at)];
    case "merged": {
      const out = [
        score(trace, "outcome", "outcome", { dataType: "CATEGORICAL", value: "merged" }, at),
        score(trace, "cycle_minutes", "cycle_minutes", { dataType: "NUMERIC", value: Math.round((num(detail.cycleMs) / 60_000) * 10) / 10 }, at),
      ];
      if (task) out.splice(1, 0, score(trace, "merged_as_is", "merged_as_is", { dataType: "BOOLEAN", value: mergedAsIs(task) ? 1 : 0 }, at, detail.auto ? "Merged by the factory" : "Merged by a person"));
      return out;
    }
    case "cancelled":
    case "closed":
      return [score(trace, "outcome", "outcome", { dataType: "CATEGORICAL", value: kind }, at)];
    case "hand.raised":
    case "question.asked":
    case "steer":
      return [score(trace, `human_touchpoint-${kind}-${at}`, "human_touchpoints", { dataType: "NUMERIC", value: 1 }, at, kind === "hand.raised" ? `hand raised: ${String(detail.reason ?? "")}` : kind === "steer" ? "steered" : "question asked")];
    default:
      return [];
  }
}

export interface LangfuseConfig {
  publicKey: string;
  secretKey: string;
  host?: string;
}

/** Posts a batch to Langfuse. Null when every event was taken, otherwise what went wrong, for the person. */
export async function ingest(cfg: LangfuseConfig, batch: IngestionEvent[], fetchFn: typeof fetch = fetch): Promise<string | null> {
  const host = (cfg.host || LANGFUSE_DEFAULT_HOST).replace(/\/+$/, "");
  let res: Response;
  try {
    res = await fetchFn(`${host}/api/public/ingestion`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Basic ${btoa(`${cfg.publicKey}:${cfg.secretKey}`)}` },
      body: JSON.stringify({ batch, metadata: { sdk_name: "maple-factory" } }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (e) {
    return `Couldn't reach Langfuse at ${host}: ${(e as Error).message}`;
  }
  if (res.status === 401 || res.status === 403) return `Langfuse refused the keys (${res.status}): check the public and secret key, and the host.`;
  if (!res.ok) return `Langfuse answered ${res.status}: ${(await res.text().catch(() => "")).slice(0, 200)}`;
  // 207: each event's own outcome.
  const body = (await res.json().catch(() => null)) as { errors?: { id: string; status: number; message?: string; error?: unknown }[] } | null;
  const errors = body?.errors ?? [];
  if (!errors.length) return null;
  const first = errors[0];
  return `Langfuse refused ${errors.length} of ${batch.length} events (${first.status}: ${first.message ?? JSON.stringify(first.error ?? "")})`.slice(0, 500);
}

/** How the sink reaches the integration's settings and status (integrations/registry.ts IntegrationAccess). */
export interface LangfuseAccess {
  config(kind: IntegrationKind): Promise<Record<string, string> | null>;
  event(kind: IntegrationKind, error?: string): Promise<void>;
}

/**
 * What the engine calls. A no-op while Langfuse is off or not set up; sends in the background, and only
 * tells the apps how it went when that changes (the first success, a failure, a recovery), not on every
 * cost update.
 */
export class LangfuseSink {
  /** How the last send went: null not yet, "" fine, otherwise its error. */
  private last: string | null = null;

  constructor(private access: LangfuseAccess, private waitUntil: (p: Promise<unknown>) => void, private fetchFn: typeof fetch = (...a) => fetch(...a)) {}

  /** The task's trace, on its own: when it's created or renamed. */
  trace(task: TraceTask) {
    this.send(task, () => []);
  }

  stat(task: TraceTask & MergeTask, kind: StatKind, detail: Record<string, unknown>, at: number) {
    // Cheap check first: most kinds have no score.
    if (!statEvents("x", kind, detail, at, task).length) return;
    this.send(task, (trace) => statEvents(trace, kind, detail, at, task));
  }

  cost(task: TraceTask, c: SessionCost) {
    this.send(task, (trace) => [generationEvent(trace, c)]);
  }

  /** One test trace, now: null when Langfuse took it, otherwise its error (also kept as the last error). */
  async test(): Promise<string | null> {
    const cfg = await this.access.config("langfuse");
    if (!cfg) return "Langfuse is off or isn't set up: save its keys first.";
    const at = Date.now();
    const trace = await traceId(`test-${at}`);
    const error = await ingest(cfg as unknown as LangfuseConfig, [
      { id: `${trace}-trace`, type: "trace-create", timestamp: iso(at), body: { id: trace, timestamp: iso(at), name: "Maple Factory test trace", tags: ["maple-factory", "test"], metadata: { source: "maple-factory", test: true } } },
    ], this.fetchFn);
    await this.note(error);
    return error;
  }

  private send(task: TraceTask, build: (trace: string) => IngestionEvent[]) {
    this.waitUntil(this.flush(task, build).catch((e) => console.error("langfuse:", e)));
  }

  private async flush(task: TraceTask, build: (trace: string) => IngestionEvent[]) {
    const cfg = await this.access.config("langfuse");
    if (!cfg) return;
    const trace = await traceId(task.id);
    const now = Date.now();
    // The trace rides along with every batch (it's an upsert), so a task from before Langfuse was set up
    // still gets its name and tags.
    await this.note(await ingest(cfg as unknown as LangfuseConfig, [traceEvent(trace, task, now), ...build(trace)], this.fetchFn));
  }

  private async note(error: string | null) {
    const now = error ?? "";
    if (now === this.last) return;
    this.last = now;
    await this.access.event("langfuse", error ?? undefined);
  }
}
