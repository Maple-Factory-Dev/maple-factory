// The whole factory loop against `wrangler dev` and a real runner whose agents.toml has the
// `scripted` agent (test/scripted-agent.mjs):
//   node server/test/e2e-factory.mjs http://localhost:8788 <machine> <repo folder>
// Checks an 11-letter prefix is refused, makes a goal with an 8-letter prefix on a local repo (whose origin is a bare repo), then a task, and drives it through
// planning, approval, building (where a person attests to both Done when items, and the agent's
// later proof leaves them be), two review rounds, human review and merge, checking origin's main.

import { execFileSync } from "node:child_process";

const [base = "http://localhost:8788", machine = "dev-mac", folder] = process.argv.slice(2);
if (!folder) throw new Error("usage: e2e-factory.mjs <server> <machine> <repo folder>");
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();

const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
const errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") for (const t of m.tasks) tasks.set(t.id, t);
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") errors.push(m.message);
  poke?.();
};
const send = (m) => feed.send(JSON.stringify(m));
const wait = async (what, test, ms = 30000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (errors.length) throw new Error(`server said: ${errors.join("; ")}`);
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => { poke = r; setTimeout(r, 250); });
  }
};
const step = (text) => console.log(`✓ ${text}`);

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => tasks.size >= 0 && true);

// Prefixes run to 10 letters or digits; an 11th is refused.
send({ type: "goal.save", goal: { id: "", name: "E2E too long", prefix: "ABCDEFGHIJK", color: "#2EA043", summary: "", lead: "", folder, base: "main" } });
await new Promise((r) => setTimeout(r, 500));
const refusal = "A goal's prefix is 1–10 letters or digits, starting with a letter.";
if (!errors.includes(refusal)) throw new Error(`an 11-letter prefix wasn't refused: ${JSON.stringify(errors)}`);
errors.length = 0;
step(`ABCDEFGHIJK refused: ${refusal}`);

// Longer than the old 6, like PLATFORM: its tasks are PLATF123-1.
const prefix = `PLATF${String(Date.now() % 1000).padStart(3, "0")}`;
send({ type: "goal.save", goal: { id: "", name: `E2E ${prefix}`, prefix, color: "#2EA043", summary: "End-to-end test", lead: "", folder, base: "main" } });
await new Promise((r) => setTimeout(r, 500));
const goals = await (async () => {
  // The goal's id comes back on goal.updated; read it from a fresh snapshot.
  const again = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  await new Promise((r) => (again.onopen = r));
  again.send(JSON.stringify({ type: "subscribe" }));
  const snap = await new Promise((r) => (again.onmessage = (e) => { const m = JSON.parse(e.data); if (m.type === "snapshot") r(m); }));
  again.close();
  return snap.goals;
})();
const goal = goals.find((g) => g.prefix === prefix);
if (!goal) throw new Error("goal wasn't saved");
step(`goal ${goal.name} (${goal.id})`);

send({ type: "task.create", goal: goal.id, title: "Say hello", brief: "Add hello.txt with a greeting. [attest]", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;
await wait("planning", () => tasks.get(id)?.worker?.role === "planner");
step(`${id} planning on ${tasks.get(id).machine}`);

let t = await wait("plan", () => tasks.get(id)?.state === "awaitingApproval" && tasks.get(id));
step(`plan v${t.planVersion}: ${t.plan.length} steps, ${t.doneWhen.length} checks, ${t.mockups.length} mockups, risk ${t.risk.level}`);

send({ type: "task.approvePlan", id });
await wait("builder", () => tasks.get(id)?.worker?.role === "builder");
step("approved; builder started");

// Attest to both items while it builds: one with a reason, one without. The builder waits for them,
// then proves both anyway; its proof mustn't replace a person's sign-off.
send({ type: "task.checkedIt", id, item: 0, note: "  Opened hello.txt myself  " });
send({ type: "task.checkedIt", id, item: 1 });
t = await wait("attestations", () => tasks.get(id)?.doneWhen.every((d) => d.evidence?.attested) && tasks.get(id));
const attestedOk = (t) => {
  const [a, b] = t.doneWhen;
  for (const d of t.doneWhen) {
    if (d.status !== "proven" || d.evidence.attested !== true || d.evidence.by === "builder") throw new Error(`not attested: ${JSON.stringify(d)}`);
  }
  if (a.evidence.reason !== "Opened hello.txt myself") throw new Error(`reason: ${JSON.stringify(a.evidence.reason)}`);
  if (b.evidence.reason != null) throw new Error(`no reason was given, got ${JSON.stringify(b.evidence.reason)}`);
};
attestedOk(t);
const by = t.doneWhen[0].evidence.by;
for (const text of [`attested "${t.doneWhen[0].text}": Opened hello.txt myself`, `attested "${t.doneWhen[1].text}"`]) {
  if (!t.events.some((e) => e.who === by && e.text === text)) throw new Error(`no timeline event ${JSON.stringify(text)}`);
}
step(`attested both as ${by}: "${t.doneWhen[0].evidence.summary}", "${t.doneWhen[1].evidence.summary}"`);

t = await wait("review round 1", () => tasks.get(id)?.autoReview?.rounds[0]?.verdict === "changesRequested" && tasks.get(id), 60000);
step(`round 1: ${t.autoReview.findings.length} finding(s); PR #${t.pr.number} at ${t.pr.head?.slice(0, 7)}`);

t = await wait("review round 2", () => tasks.get(id)?.autoReview?.rounds[1]?.verdict === "passed" && tasks.get(id), 90000);
step(`round 2 passed; findings open: ${t.autoReview.findings.filter((f) => f.status === "open").length}`);
if (t.doneWhen.some((d) => d.status !== "proven")) throw new Error("not every item is proven");
attestedOk(t);
if (t.events.some((e) => e.who === "builder" && e.text.startsWith("proved"))) throw new Error("the builder's proof replaced an attestation");
step("after two builds' proofs, both items are still attested");

if (t.reviewsNeeded > 0) {
  send({ type: "task.approveChanges", id });
  await wait("review", () => tasks.get(id)?.reviews.length === 1);
  send({ type: "task.merge", id });
} else {
  step(`${t.risk.level} risk needs no human review: the factory merges it`);
}
t = await wait("merge", () => tasks.get(id)?.state === "merged" && tasks.get(id), 30000);
step(`merged: ${t.events.at(-1).text}`);

const origin = execFileSync("git", ["-C", folder, "remote", "get-url", "origin"], { encoding: "utf8" }).trim();
const hello = execFileSync("git", ["-C", origin, "show", "main:hello.txt"], { encoding: "utf8" });
if (!hello.includes(id)) throw new Error(`origin's main has ${JSON.stringify(hello)}`);
step(`origin main has hello.txt: ${JSON.stringify(hello.split("\n")[0])}`);
console.log(`\n${t.events.map((e) => `  ${e.who}: ${e.text}`).join("\n")}`);
feed.close();
process.exit(0);
