// Comments people leave on a task's pull request on GitHub (MF-424), against the fake GitHub (test/fake-github.mjs):
//   node server/test/e2e-github-comments.mjs http://localhost:8788 <repo folder> [fake GitHub URL] [app slug]
// Set up as for e2e-github.mjs (the server's GitHub App vars and GITHUB_APP_SLUG, the runner's MAPLE_TASK_PUSH_URL /
// MAPLE_TASK_FETCH_URL, origin https://github.com/acme/greeter.git, the fake with --webhook-url pointing at the server).
// Checks: a signed issue_comment, pull_request_review and pull_request_review_comment for a task's pull request land on
// the task's comments, each with source "github", the author's login and its GitHub URL; a redelivery adds nothing; the
// factory's own app (<slug>[bot], sender type Bot) isn't brought back in; a comment on a pull request no task owns gets
// a 204 and changes no task; a bad signature is a 401.

const [base = "http://localhost:8788", folder = "/tmp/mfgh/greeter", gh = "http://localhost:18803", slug = "maple-factory-dev"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
const tasks = new Map();
let goals = [];
let errors = [];
let poke = null;
feed.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "snapshot") { goals = m.goals; for (const t of m.tasks) tasks.set(t.id, t); }
  if (m.type === "goal.updated") goals = [...goals.filter((g) => g.id !== m.goal.id), m.goal];
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
const settle = () => new Promise((r) => setTimeout(r, 1500));
const step = (text) => console.log(`✓ ${text}`);
const fail = (text) => { throw new Error(text); };
const comment = async (body) => (await fetch(`${gh}/_comment`, { method: "POST", body: JSON.stringify({ owner: "acme", repo: "greeter", ...body }) })).json();
const fromGitHub = (id) => (tasks.get(id)?.comments ?? []).filter((c) => c.source === "github");
const allComments = () => JSON.stringify([...tasks.values()].map((t) => [t.id, t.comments.map((c) => c.id)]));

await new Promise((r) => (feed.onopen = r));
send({ type: "subscribe" });
await wait("snapshot", () => true);
const prefix = `GC${Date.now() % 1000}`;
send({ type: "goal.save", goal: { id: "", name: `GitHub comments ${prefix}`, prefix, color: "#8B5CF6", summary: "Comments from GitHub", lead: "", folder, base: "main" } });
const goal = await wait("goal", () => goals.find((g) => g.prefix === prefix));
const id = `${prefix}-1`;
send({ type: "task.create", goal: goal.id, title: "Say hello", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
await wait(`${id} plan`, () => tasks.get(id)?.state === "awaitingApproval", 60000);
send({ type: "task.approvePlan", id });
const { number } = await wait(`${id} pull request`, () => tasks.get(id)?.pr?.url && tasks.get(id).pr, 90000);
// Once its review settles: the builder's round in flight saves the task it loaded before (not this change's to fix).
await wait(`${id} review passed`, () => tasks.get(id)?.autoReview?.rounds.at(-1)?.verdict === "passed" && !tasks.get(id).worker, 120000);
step(`${id} opened pull request #${number} on acme/greeter and passed review`);

// 1. A conversation comment, a review and an inline comment, each signed as GitHub signs them.
const sent = [
  await comment({ number, on: "conversation", author: "octocat", body: "Could the greeting say good morning too?" }),
  await comment({ number, on: "review", author: "hubot", state: "changes_requested", body: "Needs a newline at the end." }),
  await comment({ number, on: "line", author: "monalisa", body: "Typo here.", path: "hello.txt", line: 1 }),
];
for (const s of sent) if (s.status !== 204) fail(`${s.kind} answered ${s.status}`);
const got = await wait("three GitHub comments", () => fromGitHub(id).length >= 3 && fromGitHub(id));
const want = [
  ["octocat", "Could the greeting say good morning too?", null, sent[0].payload.comment.html_url],
  ["hubot", "Needs a newline at the end.", "Review · requested changes", sent[1].payload.review.html_url],
  ["monalisa", "Typo here.", "hello.txt:1", sent[2].payload.comment.html_url],
];
for (const [author, text, anchor, url] of want) {
  const c = got.find((c) => c.author === author) ?? fail(`no comment from ${author}: ${JSON.stringify(got)}`);
  if (c.text !== text || (c.anchor ?? null) !== anchor || c.url !== url || !c.url.startsWith("https://github.com/acme/greeter/pull/")) fail(`${author}'s comment is ${JSON.stringify(c)}`);
  step(`${sent[want.findIndex((w) => w[0] === author)].kind}: ${author} "${c.text}" (source ${c.source}, ${c.anchor ?? "no anchor"}, ${c.url})`);
}

// 2. GitHub delivers the same events again: nothing new.
for (const [i, on] of ["conversation", "review", "line"].entries()) {
  const p = sent[i].payload;
  const c = p.comment ?? p.review;
  await comment({ number, on, author: c.user.login, body: c.body, state: c.state, path: c.path, line: c.line, id: c.id });
}
await settle();
if (fromGitHub(id).length !== 3) fail(`a redelivery added comments: ${fromGitHub(id).length}`);
step("redelivering all three adds nothing (ids come from GitHub's)");

// 3. The factory's own comments don't come back in.
const own = [
  await comment({ number, on: "conversation", author: `${slug}[bot]`, bot: true, body: "Cancelled in the factory." }),
  await comment({ number, on: "conversation", author: "some-ci", bot: true, body: "Deploy preview ready." }),
  await comment({ number, on: "review", author: `${slug}[bot]`, bot: true, state: "commented", body: "Review from the factory." }),
];
for (const s of own) if (s.status !== 204) fail(`${s.kind} answered ${s.status}`);
await settle();
if (fromGitHub(id).length !== 3) fail(`a bot's comment was added: ${JSON.stringify(fromGitHub(id).map((c) => c.author))}`);
step(`comments from ${slug}[bot] and other bots (sender type Bot) aren't added`);

// 4. A pull request no task owns: 204, no task changes.
const before = allComments();
const stray = await comment({ number: 9999, on: "conversation", author: "octocat", body: "Not one of yours." });
const strayLine = await comment({ number: 9999, on: "line", author: "octocat", body: "Nor this.", path: "x.txt", line: 2 });
if (stray.status !== 204 || strayLine.status !== 204) fail(`unowned PR answered ${stray.status}/${strayLine.status}`);
await settle();
if (allComments() !== before) fail("a comment on an unowned pull request changed a task");
step("comments on pull request #9999 (no task owns it) answer 204 and change no task");

// 5. A bad signature is refused.
const forged = await comment({ number, on: "conversation", author: "mallory", body: "Forged.", badSignature: true });
if (forged.status !== 401) fail(`a bad signature answered ${forged.status}`);
await settle();
if (fromGitHub(id).some((c) => c.author === "mallory")) fail("the forged comment landed");
step("a webhook with a bad signature is a 401 and adds nothing");

send({ type: "task.cancel", id });
process.exit(0);
