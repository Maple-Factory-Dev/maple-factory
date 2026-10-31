// A review of a task's diff (`task.review`), against the fake GitHub (test/fake-github.mjs):
//   node server/test/e2e-review.mjs http://localhost:8788 <repo folder> [fake GitHub URL]
// Set up as for e2e-github.mjs (the server's GitHub App vars, the runner's MAPLE_TASK_PUSH_URL /
// MAPLE_TASK_FETCH_URL, the repo folder's origin https://github.com/acme/greeter.git), plus the
// scripted agent. Checks: GET /api/tasks/:id/threads reads the pull request's review threads from
// GitHub; a review with 3 notes posts 3 comments anchored to their lines with the code, and one change
// request that sends the task in review back to its builder, which applies it; a review of a plan
// waiting for approval goes to the planner; one while the builder works is typed into its session. A
// teammate's `task.requestReview` on a passed task opens one more round with their focus (in the
// reviewer's prompt), keeps the approvals already given, and the task merges once it passes; one while
// a round runs, or on a task that isn't in review, is refused.

const [base = "http://localhost:8788", folder = "/tmp/mfgh/greeter", gh = "http://localhost:18803"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
const errors = [];
const requested = new Map();
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
  if (m.type === "task.updated") tasks.set(m.task.id, m.task);
  // Each round a teammate asked for, as it was first seen running.
  const round = m.task?.autoReview?.rounds.at(-1);
  if (round?.focus && round.verdict === "inProgress" && !requested.has(`${m.task.id}#${round.number}`)) requested.set(`${m.task.id}#${round.number}`, { ...round });
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
const check = (ok, why) => { if (!ok) throw new Error(why); };
// "[risky]" keeps the factory from merging on its own; ann gives the second approvals.
// Sends each message in order on one socket; resolves to the errors it got back.
const ann = async (...ms) => {
  const { token } = await (await fetch(`${base}/dev/token?as=ann`, { method: "POST" })).json();
  const sock = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const said = [];
  sock.onmessage = (e) => { const m = JSON.parse(e.data); if (m.type === "error") said.push(m.message); };
  await new Promise((r) => (sock.onopen = r));
  for (const m of ms) sock.send(JSON.stringify(m));
  await new Promise((r) => setTimeout(r, 1000));
  sock.close();
  return said;
};

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => true);
const prefix = `RV${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `Review ${prefix}`, prefix, color: "#3B82F6", summary: "Reviews of the diff", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
step(`goal ${goal.name} on ${folder} (origin github.com/acme/greeter)`);

// A task in review with its pull request open.
send({ type: "task.create", goal: goal.id, title: "Review my greeting", brief: "[risky] Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id = `${prefix}-1`;
await wait("plan", () => tasks.get(id)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id });
await ann({ type: "task.approvePlan", id });
const passed = (x) => x?.state === "reviewing" && x.pr?.number && x.autoReview?.rounds.at(-1)?.verdict === "passed";
let t = await wait("review passed", () => passed(tasks.get(id)) && tasks.get(id), 180000);
step(`${id} is in review with pull request #${t.pr.number}`);

// Its review threads, from GitHub's GraphQL.
const none = await fetch(`${base}/api/tasks/${id}/threads`, { headers: { authorization: `Bearer ${token}` } });
check(none.ok && (await none.json()).length === 0, "threads before anyone reviewed on GitHub");
await fetch(`${gh}/_threads`, {
  method: "POST",
  body: JSON.stringify({
    owner: "acme", repo: "greeter", number: t.pr.number,
    threads: [
      { path: "hello.txt", line: 1, comments: [{ author: "octocat", body: "Say hello to the world too?" }, { author: "afomera", body: "Good idea." }] },
      { path: "hello.txt", line: 2, startLine: 1, resolved: true, comments: [{ author: "hubot", body: "Typo fixed." }] },
      { path: "README.md", line: 1, side: "LEFT", outdated: true, comments: [{ author: "octocat", body: "Old title." }] },
    ],
  }),
});
const res = await fetch(`${base}/api/tasks/${id}/threads`, { headers: { authorization: `Bearer ${token}` } });
check(res.ok, `GET /api/tasks/${id}/threads: ${res.status} ${await res.clone().text()}`);
const threads = await res.json();
check(threads.length === 3, `${threads.length} threads`);
check(threads[0].path === "hello.txt" && threads[0].line === 1 && threads[0].side === "new" && !threads[0].resolved && threads[0].comments.map((c) => c.author).join() === "octocat,afomera", JSON.stringify(threads[0]));
check(threads[1].startLine === 1 && threads[1].line === 2 && threads[1].resolved, JSON.stringify(threads[1]));
check(threads[2].side === "old" && threads[2].outdated && threads[2].comments[0].at > 0, JSON.stringify(threads[2]));
step(`GET /api/tasks/${id}/threads: ${threads.map((x) => `${x.path}:${x.startLine ? `${x.startLine}–` : ""}${x.line} (${x.side}${x.resolved ? ", resolved" : ""}${x.outdated ? ", outdated" : ""}, ${x.comments.length} comment${x.comments.length === 1 ? "" : "s"})`).join("; ")}`);

// A review of 3 notes: 3 anchored comments with the code, and one change request back to the builder.
const comments = t.comments.length;
const changes = t.changes.length;
const notes = [
  { path: "hello.txt", start: 1, end: 1, side: "new", snippet: `+hello from ${id}`, text: "Wave as well as say hello." },
  { path: "hello.txt", start: 1, end: 2, side: "new", snippet: `+hello from ${id}\n+(with a trailing newline, as review asked)`, text: "Drop the review note." },
  { path: "README.md", start: 1, end: 1, side: "old", snippet: "-# greeter", text: "Keep the README title." },
];
send({ type: "task.review", id, notes, summary: "Three things before it merges." });
t = await wait("the review", () => tasks.get(id)?.changes.length > changes && tasks.get(id));
const posted = t.comments.slice(comments);
check(posted.length === 4, `${posted.length} comments posted`);
const anchored = posted.filter((c) => /:L\d/.test(c.anchor ?? ""));
check(anchored.length === 3, `${anchored.length} anchored comments`);
check(anchored.map((c) => c.anchor).join() === "hello.txt:L1,hello.txt:L1–2,README.md:L1", anchored.map((c) => c.anchor).join());
for (const [i, c] of anchored.entries()) check(c.text === "```diff\n" + notes[i].snippet + "\n```\n" + notes[i].text, `comment ${i + 1}: ${JSON.stringify(c.text)}`);
check(posted[3].anchor === "Review" && posted[3].text === "Three things before it merges.", JSON.stringify(posted[3]));
for (const c of anchored) step(`comment on ${c.anchor}: ${JSON.stringify(c.text)}`);
const added = t.changes.slice(changes);
check(added.length === 1, `${added.length} change requests`);
const change = added[0];
check(change.anchor === "Review · 3 comments", change.anchor);
check(change.text === "Three things before it merges.\n1. hello.txt:L1: Wave as well as say hello.\n2. hello.txt:L1–2: Drop the review note.\n3. README.md:L1 (removed lines): Keep the README title.", JSON.stringify(change.text));
step(`one change request, ${change.id} (${change.anchor}, ${change.status}): ${JSON.stringify(change.text)}`);
check(t.events.some((e) => e.text === "asked for a change: a review of 3 comments"), t.events.map((e) => e.text).join(" / "));
await wait("back to building", () => tasks.get(id)?.state === "building");
step("it went back to the builder");
t = await wait("applied", () => tasks.get(id)?.changes.find((c) => c.id === change.id)?.status === "applied" && tasks.get(id), 120000);
step(`the builder applied ${change.id}`);
send({ type: "task.cancel", id });
await wait("cancelled", () => tasks.get(id)?.state === "cancelled");

// A review of a plan waiting for approval goes to the planner, which posts plan v2.
send({ type: "task.create", goal: goal.id, title: "Review my plan", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id2 = `${prefix}-2`;
await wait("plan 2", () => tasks.get(id2)?.state === "awaitingApproval" && tasks.get(id2).worker == null, 60000);
const noPR = await fetch(`${base}/api/tasks/${id2}/threads`, { headers: { authorization: `Bearer ${token}` } });
check(noPR.ok && (await noPR.json()).length === 0, "threads for a task without a pull request");
step(`GET /api/tasks/${id2}/threads with no pull request: []`);
send({ type: "task.review", id: id2, notes: [{ path: "hello.txt", start: 1, end: 1, side: "new", snippet: "+hi", text: "Two greetings." }] });
await wait("planning", () => tasks.get(id2)?.state === "planning");
t = await wait("plan v2", () => tasks.get(id2)?.state === "awaitingApproval" && tasks.get(id2).planVersion === 2 && tasks.get(id2), 60000);
check(t.changes.at(-1).anchor === "Review · 1 comment", t.changes.at(-1).anchor);
step(`${id2}: a review of its plan went to the planner, which posted plan v${t.planVersion}`);
send({ type: "task.cancel", id: id2 });
await wait("cancelled 2", () => tasks.get(id2)?.state === "cancelled");

// A review while the builder works is typed into its session.
send({ type: "task.create", goal: goal.id, title: "Review while it builds", brief: "[slow-build] Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id3 = `${prefix}-3`;
await wait("plan 3", () => tasks.get(id3)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id: id3 });
await wait("builder", () => tasks.get(id3)?.worker?.role === "builder", 60000);
await new Promise((r) => setTimeout(r, 2000));
send({ type: "task.review", id: id3, notes: [{ path: "hello.txt", start: 1, end: 1, side: "new", snippet: "+hello", text: "Say bonjour too." }] });
t = await wait("applying", () => tasks.get(id3)?.changes.at(-1)?.status === "applying" && tasks.get(id3));
const typed = t.changes.at(-1);
step(`${id3}: ${typed.id} typed into the builder's session`);
await wait("applied 3", () => tasks.get(id3)?.changes.find((c) => c.id === typed.id)?.status === "applied", 120000);
step(`${typed.id} applied`);
send({ type: "task.cancel", id: id3 });
await wait("cancelled 3", () => tasks.get(id3)?.state === "cancelled");

// A teammate asks for one more review round with their own focus; approvals already given stay.
send({ type: "task.create", goal: goal.id, title: "Review it for security", brief: "[risky] Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
const id4 = `${prefix}-4`;
await wait("plan 4", () => tasks.get(id4)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id: id4 });
await ann({ type: "task.approvePlan", id: id4 });
t = await wait("review 4 passed", () => passed(tasks.get(id4)) && tasks.get(id4), 180000);
const rounds = t.autoReview.rounds.length;
send({ type: "task.approveChanges", id: id4 });
await wait("approved", () => tasks.get(id4)?.reviews.length === 1);
const focus = "Check security: could hello.txt leak anything?";
// Another right behind it, while that round runs: refused.
const busy = await ann({ type: "task.requestReview", id: id4, focus }, { type: "task.requestReview", id: id4, focus: "And error handling." });
check(busy.length === 1 && /already running/.test(busy[0]), `a request during a round wasn't refused: ${busy.join("; ")}`);
t = await wait("round requested", () => tasks.get(id4)?.autoReview.rounds.length === rounds + 1 && requested.get(`${id4}#${rounds + 1}`) && tasks.get(id4));
const asked = requested.get(`${id4}#${rounds + 1}`);
check(asked.focus === focus && asked.by === "ann", JSON.stringify(asked));
check(t.comments.some((c) => c.author === "ann" && c.anchor === "Review request" && c.text === focus), "no Review request comment");
check(t.events.some((e) => e.text === `asked for a review: ${focus}`), t.events.map((e) => e.text).join(" / "));
step(`ann asked for round ${asked.number}: ${JSON.stringify(asked)}`);
step(`a request while round ${asked.number} runs is refused: ${busy.join("; ")}`);
t = await wait("requested round passed", () => passed(tasks.get(id4)) && tasks.get(id4).autoReview.rounds.length === rounds + 1 && tasks.get(id4), 120000);
check(t.autoReview.summary.includes(`Looked at what ann asked: ${focus}`), `the reviewer's prompt didn't carry the focus: ${t.autoReview.summary}`);
step(`the reviewer's prompt had the focus; it says: ${JSON.stringify(t.autoReview.summary)}`);
check(t.reviews.join() === "afomera", `approvals after the round: ${t.reviews.join()}`);
step(`approvals kept through round ${asked.number}: ${t.reviews.join()}`);
await ann({ type: "task.approveChanges", id: id4 });
t = await wait("approved 4", () => tasks.get(id4)?.reviews.length === 2 && tasks.get(id4));
await fetch(`${gh}/_checks`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "greeter", sha: t.pr.head, runs: [{ name: "test", conclusion: "success" }] }) });
await wait("CI passed", () => tasks.get(id4)?.pr.checks.every((c) => c.status === "passed"));
send({ type: "task.merge", id: id4 });
await wait("merged 4", () => tasks.get(id4)?.state === "merged", 60000);
step(`${id4} merged after the requested round passed`);

// Not in review: refused.
send({ type: "task.requestReview", id: id3, focus: "Too late." });
await new Promise((r) => setTimeout(r, 1000));
const late = errors.splice(0);
check(late.some((e) => /isn't in review/.test(e)), `a request on a cancelled task wasn't refused: ${late.join("; ")}`);
step(`a request on a task that isn't in review is refused: ${late.join("; ")}`);

// Nothing working on it: refused.
send({ type: "task.review", id: id3, notes: [{ path: "hello.txt", start: 1, end: 1, side: "new", snippet: "+x", text: "Too late." }] });
await new Promise((r) => setTimeout(r, 1000));
check(errors.splice(0).some((e) => /nothing working on it/.test(e)), "a review of a cancelled task wasn't refused");
step("a review of a cancelled task is refused");
process.exit(0);
