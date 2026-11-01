// Artifacts in the pull request (MF-209), with this script as the runner and the fake GitHub:
//   node server/test/e2e-artifacts-pr.mjs http://localhost:8788 [fake GitHub URL]
// The server needs GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, GITHUB_API_URL (the fake) and PUBLIC_URL; the fake
// runs with --installed acme/greeter. Like e2e-artifacts.mjs this script enrolls a runner and plays its
// sessions, and it reports the push itself (`task.finished`, pushed with the app), so no real runner is needed.
// Checks: the builder shares "Change walkthrough" before it finishes and the pull request it opens has an
// Artifacts block listing it, linked to the task page with it picked; after review asks for changes, the
// builder's v2 share PATCHes the body with v2 and keeps what a person wrote around the block; with GitHub
// refusing body edits, a v3 share still succeeds and only adds "couldn't update the pull request's
// artifacts: …" to the timeline.

const [base = "http://localhost:8788", gh = "http://localhost:18803"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const member = { authorization: `Bearer ${token}` };

const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: member })).json();
const runnerId = `artifacts-pr-${Date.now().toString(36)}`;
const enrolled = await (await fetch(`${base}/runner/enroll`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
})).json();
const runner = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
await new Promise((r, j) => { runner.onopen = r; runner.onerror = j; });
const sessions = [];
const replies = new Map();
runner.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "ping") runner.send(JSON.stringify({ type: "pong" }));
  if (m.type === "session.open") sessions.push(m);
  if (m.type === "mcp.response") replies.get(m.reqId)?.(m);
};
const toServer = (m) => runner.send(JSON.stringify(m));
toServer({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
const call = (session, tool, args) => new Promise((resolve) => {
  const reqId = crypto.randomUUID();
  replies.set(reqId, resolve);
  toServer({ type: "mcp.request", reqId, session, tool, args });
});
/** Uploads a walkthrough page and shares it under `title`, as proof.rs `prepare_artifact` does. */
const share = async (session, task, title, html, summary) => {
  const up = await (await fetch(`${base}/runner/artifact/${task}?runner=${runnerId}&name=walkthrough.html`, {
    method: "PUT", headers: { "content-type": "text/html", authorization: `Bearer ${enrolled.token}` }, body: html,
  })).json();
  return call(session, "share_artifact", { title, summary, file: { key: up.key, name: "walkthrough.html", type: up.type, bytes: up.bytes } });
};

const feed = new WebSocket(`${ws}/client/connect`, { headers: member });
const tasks = new Map();
let goals = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  if (m.type === "error") console.log(`server said: ${m.message}`);
  poke?.();
};
const send = (m) => feed.send(JSON.stringify(m));
const wait = async (what, test, ms = 20000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = await test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => { poke = r; setTimeout(r, 200); });
  }
};
const ghLog = async () => (await fetch(`${gh}/_log`)).json();
await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });

const prefix = `AP${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Artifacts PR ${prefix}`, prefix, color: "#14A866", summary: "Walkthroughs in the PR", lead: "", folder: "/tmp/mf-artifacts-pr", base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
send({ type: "task.create", goal: goal.id, title: "Greet in the README", brief: "Say hello in the README.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;

const planner = await wait("planner", () => sessions.find((s) => s.taskId === id));
await call(planner.id, "submit_plan", {
  summary: "Add a greeting.", steps: [{ text: "Add the greeting", file: "README.md" }],
  doneWhen: [{ text: "The README says hello", proof: "terminal" }],
  risk: { level: "medium", reasons: ["Docs."], areas: [] }, footprint: { files: 1, lines: 2 },
});
await wait("plan", () => ["awaitingApproval", "building"].includes(tasks.get(id)?.state));
if (tasks.get(id).state === "awaitingApproval") send({ type: "task.approvePlan", id });
const builder = await wait("builder", () => sessions.find((s) => s.taskId === id && s.id !== planner.id));
check(/Before `finish`, share one artifact titled "Change walkthrough"/.test(builder.prompt ?? ""), "the builder's prompt asks for a Change walkthrough before finish");

// Round 1: share the walkthrough, then the push (the runner's report of it), and the PR opens.
const v1 = await share(builder.id, id, "Change walkthrough", "<!doctype html><h1>README: before → after</h1>", "The README before and after");
check(!v1.error, `the builder shares "Change walkthrough" (${v1.result?.summary ?? v1.error})`);
toServer({ type: "task.finished", taskId: id, ok: true, pushed: "app", owner: "acme", repo: "greeter", branch: `agent/${id.toLowerCase()}`, base: "main", commit: "a".repeat(40) });
const opened = await wait("the pull request", async () => (await ghLog()).log.find((l) => l.method === "POST" && /\/repos\/acme\/greeter\/pulls$/.test(l.path) && l.body?.title?.startsWith(id)));
const t1 = tasks.get(id);
const a1 = t1.artifacts.find((a) => a.title === "Change walkthrough");
const link1 = `/t/${id}?artifact=${a1.id}`;
check(opened.body.body.includes("<!-- maple:artifacts -->\n## Artifacts") && opened.body.body.includes(`[Change walkthrough](`) && opened.body.body.includes(link1) && opened.body.body.includes("(html, shared by the builder)"),
  `the opened PR's body lists it, linked to ${link1}`);
console.log(opened.body.body.slice(opened.body.body.indexOf("<!-- maple:artifacts -->")).split("\n").map((l) => `     | ${l}`).join("\n"));
const prNumber = (await wait("the PR number", () => tasks.get(id)?.pr?.url && tasks.get(id))).pr.number;

// A person edits the description on GitHub: their words go around the factory's block.
const pulls0 = (await ghLog()).pulls.find((p) => p.number === prNumber);
check(pulls0?.body === opened.body.body, "the fake GitHub has the body");
const person = `A note a person added on GitHub.\n\n${opened.body.body}\n\nAnd a line below it, by @bo.`;
await fetch(`${gh}/_setBody`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ number: prNumber, body: person }) });

// Review asks for changes; the builder comes back for round 2.
const reviewer = await wait("reviewer", () => sessions.find((s) => s.taskId === id && /review agent/.test(s.prompt ?? "")));
const review = await call(reviewer.id, "submit_review", {
  verdict: "changesRequested", summary: "Add a second line.",
  ask: [{ text: "Say hello", verdict: "met" }], proofs: [{ text: "The README says hello", verdict: "met" }],
  findings: [{ kind: "code", severity: "major", text: "Add a second line.", file: "README.md:1" }], fixed: [],
});
check(!review.error, `review asks for changes (${review.result?.summary ?? review.error})`);
const builder2 = await wait("builder round 2", () => sessions.find((s) => s.taskId === id && /You are the builder/.test(s.prompt ?? "") && s.id !== builder.id));
const before = (await ghLog()).log.filter((l) => l.method === "PATCH" && l.path === `/repos/acme/greeter/pulls/${prNumber}` && typeof l.body?.body === "string").length;
const v2 = await share(builder2.id, id, "Change walkthrough", "<!doctype html><h1>README: before → after (v2)</h1>", "Now with the second line");
check(!v2.error && v2.result?.data?.version === 2, `the builder shares v2 after review (${v2.result?.summary ?? v2.error})`);
const patched = await wait("the PATCH with v2", async () => {
  const l = (await ghLog()).log.filter((x) => x.method === "PATCH" && x.path === `/repos/acme/greeter/pulls/${prNumber}` && typeof x.body?.body === "string");
  return l.length > before && l.at(-1);
});
const a2 = await wait("v2 in the feed", () => tasks.get(id)?.artifacts.find((a) => a.title === "Change walkthrough" && a.version === 2));
// The summary shows only if the factory knows acme/greeter is private (the fake's repos are), as with evidence.
check(patched.body.body.includes(`?artifact=${a2.id}) (html, v2, shared by the builder)`) && !patched.body.body.includes(a1.id),
  "the PATCHed body lists v2 in place of v1");
check(patched.body.body.split("<!-- maple:artifacts -->").length === 2 && patched.body.body.startsWith("A note a person added on GitHub.\n\nBuilt by Maple Factory for") && patched.body.body.endsWith("\n\nAnd a line below it, by @bo."),
  "only the block changed: the person's lines above and below it stay");
console.log(patched.body.body.slice(patched.body.body.indexOf("<!-- maple:artifacts -->")).split("\n").map((l) => `     | ${l}`).join("\n"));

// GitHub refuses body edits: the share still works, and the timeline says what happened.
await fetch(`${gh}/_failBody`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ on: true }) });
const v3 = await share(builder2.id, id, "Change walkthrough", "<!doctype html><h1>v3</h1>", "Third pass");
check(!v3.error && v3.result?.data?.version === 3, `a v3 share succeeds while GitHub refuses (${v3.result?.summary ?? v3.error})`);
const note = await wait("the timeline note", () => tasks.get(id)?.events.find((e) => e.who === "factory" && e.text.startsWith("couldn't update the pull request's artifacts:")));
check(Boolean(note), `the timeline says: "${note.text}"`);
await fetch(`${gh}/_failBody`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ on: false }) });

console.log(`${id}: ${failures ? `${failures} failed` : "all passed"}`);
process.exit(failures ? 1 : 0);
