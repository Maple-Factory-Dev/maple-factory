// Langfuse (MF-348): each stat kind becomes its score, a session's cost a generation with its tokens and
// cost, a task always gets the same trace id, the keys and host are checked on save, and the client
// reads Langfuse's 207 partial failures and 401s as errors for the integration's card.
import { test } from "node:test";
import assert from "node:assert/strict";
import { definition, langfuseHost, merged } from "../src/integrations/registry.ts";
import { LangfuseSink, generationEvent, ingest, mergedAsIs, statEvents, traceEvent, traceId, type IngestionEvent } from "../src/integrations/langfuse.ts";

const AT = Date.UTC(2026, 10, 8, 12, 0, 0);
const TRACE = "0123456789abcdef0123456789abcdef";
const TASK = { id: "MF-348", title: "Langfuse integration", repo: "Maple-Factory-Dev/maple-factory", createdAt: AT - 3_600_000, agent: "claude", goalName: "Maple Factory" };
const clean = { changes: [], autoReview: { rounds: [{ verdict: "passed" }] } };
const body = (e: IngestionEvent) => e.body as Record<string, unknown>;

test("a task's trace id is stable, 32 hex, and differs between tasks", async () => {
  const a = await traceId("MF-348");
  assert.match(a, /^[0-9a-f]{32}$/);
  assert.equal(await traceId("MF-348"), a);
  assert.notEqual(await traceId("MF-349"), a);
});

test("the trace is named after the task and tagged with its goal and repo", () => {
  const e = traceEvent(TRACE, TASK, AT);
  assert.equal(e.type, "trace-create");
  assert.deepEqual(body(e), {
    id: TRACE, timestamp: new Date(TASK.createdAt).toISOString(), name: "Langfuse integration",
    tags: ["Maple Factory", "Maple-Factory-Dev/maple-factory"], metadata: { taskId: "MF-348", agent: "claude", source: "maple-factory" },
  });
  assert.deepEqual(body(traceEvent(TRACE, { ...TASK, repo: null, goalName: null }, AT)).tags, []);
});

test("a session's cost is a generation, keyed by the session so updates replace it", () => {
  const cost = { session: "s-1", role: "builder", agent: "claude", model: "claude-opus-5-5", costUsd: 1.25, tokens: { input: 1000, output: 200, cacheRead: 5000, cacheWrite: 300 }, updated: AT };
  const e = generationEvent(TRACE, cost);
  assert.equal(e.type, "generation-create");
  assert.deepEqual(body(e), {
    id: "s-1", traceId: TRACE, name: "builder", model: "claude-opus-5-5", endTime: new Date(AT).toISOString(),
    usageDetails: { input: 1000, output: 200, cache_read_input_tokens: 5000, cache_creation_input_tokens: 300 },
    costDetails: { total: 1.25 }, metadata: { agent: "claude", role: "builder" },
  });
  // A later update: same generation id, a new event id.
  const later = generationEvent(TRACE, { ...cost, costUsd: 2, updated: AT + 30_000 });
  assert.equal(body(later).id, "s-1");
  assert.notEqual(later.id, e.id);
  // Codex gives no cost: none is sent, rather than 0.
  const codex = body(generationEvent(TRACE, { ...cost, agent: "codex", costUsd: null, model: null, tokens: { input: 10, output: 2, cacheRead: 0, cacheWrite: 0 } }));
  assert.equal(codex.costDetails, undefined);
  assert.equal(codex.model, undefined);
  assert.deepEqual(codex.usageDetails, { input: 10, output: 2 });
});

const scores = (events: IngestionEvent[]) => events.map((e) => {
  assert.equal(e.type, "score-create");
  const b = body(e);
  assert.equal(b.traceId, TRACE);
  return [b.name, b.dataType, b.value];
});

test("a review round is its verdict (categorical) and its findings (numeric), one pair per round", () => {
  const events = statEvents(TRACE, "review.round", { number: 2, verdict: "changesRequested", found: 3, fixed: 1 }, AT);
  assert.deepEqual(scores(events), [["review_verdict", "CATEGORICAL", "changesRequested"], ["review_findings", "NUMERIC", 3]]);
  assert.notEqual(body(statEvents(TRACE, "review.round", { number: 1, verdict: "passed", found: 0 }, AT)[0]).id, body(events[0]).id);
  assert.deepEqual(statEvents(TRACE, "review.round", { number: 3, verdict: "inProgress", found: 0 }, AT), []);
});

test("a plan approval is its version count", () => {
  assert.deepEqual(scores(statEvents(TRACE, "plan.approved", { version: 3, approvals: 1 }, AT)), [["plan_versions", "NUMERIC", 3]]);
});

test("a merge is its outcome, whether it went as-is, and its cycle time in minutes", () => {
  assert.deepEqual(scores(statEvents(TRACE, "merged", { auto: true, cycleMs: 5_430_000 }, AT, clean)),
    [["outcome", "CATEGORICAL", "merged"], ["merged_as_is", "BOOLEAN", 1], ["cycle_minutes", "NUMERIC", 90.5]]);
  const reviewed = { changes: [], autoReview: { rounds: [{ verdict: "changesRequested" }, { verdict: "passed" }] } };
  assert.deepEqual(scores(statEvents(TRACE, "merged", { auto: false, cycleMs: 60_000 }, AT, reviewed))[1], ["merged_as_is", "BOOLEAN", 0]);
  assert.equal(mergedAsIs({ changes: [{} as never], autoReview: null }), false);
  assert.equal(mergedAsIs({ changes: [], autoReview: null }), true);
});

test("hands, questions and steers are each one human touchpoint; cancelled and closed are outcomes", () => {
  for (const kind of ["hand.raised", "question.asked", "steer"] as const) {
    assert.deepEqual(scores(statEvents(TRACE, kind, { reason: "proofBurden" }, AT)), [["human_touchpoints", "NUMERIC", 1]]);
  }
  // Two hands are two scores, not one overwritten.
  assert.notEqual(body(statEvents(TRACE, "hand.raised", {}, AT)[0]).id, body(statEvents(TRACE, "hand.raised", {}, AT + 1)[0]).id);
  assert.deepEqual(scores(statEvents(TRACE, "cancelled", { state: "building" }, AT)), [["outcome", "CATEGORICAL", "cancelled"]]);
  assert.deepEqual(scores(statEvents(TRACE, "closed", { proposed: 2 }, AT)), [["outcome", "CATEGORICAL", "closed"]]);
  for (const kind of ["session.ended", "budget.reached", "plan.submitted", "hand.resolved"] as const) assert.deepEqual(statEvents(TRACE, kind, {}, AT), []);
});

test("Langfuse's keys and host are checked on save", () => {
  const def = definition("langfuse")!;
  assert.equal(def.webhookPath, undefined);
  const ok = merged(def, true, { publicKey: "pk-lf-1", secretKey: "sk-lf-2", host: "https://us.cloud.langfuse.com/" }, {}, {});
  assert.deepEqual(ok, { publicKey: "pk-lf-1", secretKey: "sk-lf-2", host: "https://us.cloud.langfuse.com" });
  assert.equal(merged(def, true, { publicKey: "lf-1", secretKey: "sk-lf-2" }, {}, {}), "Langfuse's public key starts with pk-lf-.");
  assert.equal(merged(def, true, { publicKey: "pk-lf-1", secretKey: "pk-lf-2" }, {}, {}), "Langfuse's secret key starts with sk-lf-.");
  assert.match(merged(def, true, { publicKey: "pk-lf-1", secretKey: "sk-lf-2", host: "http://langfuse.example.com" }, {}, {}) as string, /https:\/\//);
  assert.equal(merged(def, true, { publicKey: "pk-lf-1" }, {}, {}), "Langfuse needs its secret key.");
  // A blank secret keeps the stored one; host is optional.
  assert.deepEqual(merged(def, true, { publicKey: "pk-lf-1", secretKey: "" }, { secretKey: "sk-lf-old" }, {}), { publicKey: "pk-lf-1", secretKey: "sk-lf-old" });
  assert.equal(langfuseHost("http://localhost:3000"), "http://localhost:3000");
  assert.equal(langfuseHost("https://user:pw@langfuse.example.com"), null);
  assert.equal(langfuseHost("not a url"), null);
});

const fake = (status: number, json: unknown, seen: { url: string; init: RequestInit }[] = []): typeof fetch =>
  (async (url: string, init: RequestInit) => {
    seen.push({ url, init });
    return new Response(JSON.stringify(json), { status, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;

test("ingest posts the batch with basic auth and reads 207s and 401s", async () => {
  const seen: { url: string; init: RequestInit }[] = [];
  const cfg = { publicKey: "pk-lf-1", secretKey: "sk-lf-2", host: "https://lf.example.com/" };
  const batch = [traceEvent(TRACE, TASK, AT)];
  assert.equal(await ingest(cfg, batch, fake(207, { successes: [{ id: batch[0].id, status: 201 }], errors: [] }, seen)), null);
  assert.equal(seen[0].url, "https://lf.example.com/api/public/ingestion");
  assert.equal((seen[0].init.headers as Record<string, string>).authorization, `Basic ${btoa("pk-lf-1:sk-lf-2")}`);
  assert.deepEqual(JSON.parse(seen[0].init.body as string).batch, batch);
  assert.match((await ingest(cfg, batch, fake(207, { successes: [], errors: [{ id: "x", status: 400, message: "Invalid request data" }] })))!, /refused 1 of 1 events \(400: Invalid request data\)/);
  assert.match((await ingest(cfg, batch, fake(401, { message: "Invalid credentials" })))!, /refused the keys \(401\)/);
  // No host: Langfuse Cloud.
  const cloud: { url: string; init: RequestInit }[] = [];
  await ingest({ publicKey: "pk-lf-1", secretKey: "sk-lf-2" }, batch, fake(207, { errors: [] }, cloud));
  assert.equal(cloud[0].url, "https://cloud.langfuse.com/api/public/ingestion");
});

test("the sink is a no-op when off, and only reports a change in how it's going", async () => {
  const pending: Promise<unknown>[] = [];
  const events: (string | undefined)[] = [];
  let cfg: Record<string, string> | null = null;
  let status = 401;
  const posted: unknown[] = [];
  const sink = new LangfuseSink({ config: async () => cfg, event: async (_k, e) => void events.push(e) }, (p) => pending.push(p),
    (async (_u: string, init: RequestInit) => { posted.push(JSON.parse(init.body as string)); return new Response("{}", { status }); }) as unknown as typeof fetch);
  const task = { ...TASK, ...clean };
  const settle = async () => { await Promise.all(pending.splice(0)); };

  sink.stat(task, "merged", { cycleMs: 1 }, AT);
  await settle();
  assert.equal(posted.length, 0, "off: nothing sent");

  cfg = { publicKey: "pk-lf-1", secretKey: "sk-lf-2" };
  sink.stat(task, "session.ended", {}, AT);
  await settle();
  assert.equal(posted.length, 0, "a kind with no score sends nothing");

  sink.stat(task, "review.round", { number: 1, verdict: "passed", found: 0 }, AT);
  sink.stat(task, "steer", {}, AT);
  await settle();
  assert.equal(posted.length, 2);
  assert.deepEqual((posted[0] as { batch: IngestionEvent[] }).batch.map((e) => e.type), ["trace-create", "score-create", "score-create"]);
  assert.equal(events.length, 1, "the same 401 twice is noted once");
  assert.match(events[0]!, /401/);

  status = 207;
  sink.cost(TASK, { session: "s", role: "builder", agent: "claude", model: null, costUsd: 1, tokens: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 }, updated: AT });
  sink.trace(TASK);
  await settle();
  assert.deepEqual(events.slice(1), [undefined], "recovering clears the error, once");
});
