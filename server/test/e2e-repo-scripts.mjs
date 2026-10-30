// Per-repo worktree scripts, against `wrangler dev` and a talking-only runner (enrolled here, like
// test/fake-runner.mjs):
//   node server/test/e2e-repo-scripts.mjs http://localhost:8788
// Checks: an admin saves create/setup/teardown/archive scripts for acme/web (blank ones dropped),
// repos.updated and a new snapshot carry them, a member's repos.scripts.set is refused, and a 4 KB+
// command or a bad timeout is refused. A task on acme/web reaches the runner with the scripts in its
// TaskStart; the runner's task.progress lands on the task's timeline; archiving the goal with
// "cleanup" sends task.cleanup with the scripts, and task.cleaned's message is on the timeline too.
// Clearing every command removes the repo's scripts.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const tokenFor = async (as) => (await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json()).token;
const token = await tokenFor();
const auth = { authorization: `Bearer ${token}` };
const step = (text) => console.log(`✓ ${text}`);
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const REPO = "acme/web";
const SCRIPTS = { create: "bin/worktree-create", setup: "  bin/worktree-setup --fast  ", teardown: "", archive: "bin/worktree-archive", timeoutSecs: 120 };
const SAVED = { create: "bin/worktree-create", setup: "bin/worktree-setup --fast", archive: "bin/worktree-archive", timeoutSecs: 120 };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/** An app connection: the snapshot, broadcasts and errors it's been sent. */
async function app(tok) {
  const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${tok}` } });
  const c = { feed, errors: [], snapshot: null, tasks: new Map(), goals: [], machines: [], scripts: null, poke: null };
  feed.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { c.snapshot = m; c.goals = m.goals; c.machines = m.machines; c.scripts = m.scripts; c.repos = m.repos; for (const t of m.tasks) c.tasks.set(t.id, t); }
    if (m.type === "goal.updated") c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "machine.updated") c.machines = [...c.machines.filter((x) => x.id !== m.machine.id), m.machine];
    if (m.type === "task.updated") c.tasks.set(m.task.id, m.task);
    if (m.type === "repos.updated") { c.scripts = m.scripts; c.repos = m.repos; }
    if (m.type === "error") c.errors.push(m.message);
    c.poke?.();
  };
  c.send = (m) => feed.send(JSON.stringify(m));
  c.wait = async (what, test, ms = 30000) => {
    const deadline = Date.now() + ms;
    for (;;) {
      const hit = test();
      if (hit) return hit;
      if (c.errors.length) throw new Error(`server said: ${c.errors.join("; ")}`);
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
      await new Promise((r) => { c.poke = r; setTimeout(r, 250); });
    }
  };
  await new Promise((r) => (feed.onopen = r));
  c.send({ type: "subscribe" });
  await c.wait("snapshot", () => c.snapshot);
  return c;
}

/** A runner that opens sessions in a made-up worktree, ends them when asked, and records what it's sent. */
async function runner(runnerId) {
  const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: auth })).json();
  const enrolled = await (await fetch(`${base}/runner/enroll`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
  })).json();
  const sock = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
  await new Promise((r, j) => { sock.onopen = r; sock.onerror = j; });
  const r = { id: runnerId, opened: [], cleanups: [] };
  const say = (m) => sock.send(JSON.stringify(m));
  r.say = say;
  sock.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "session.open" && m.taskId) {
      r.opened.push(m);
      say({ type: "session.opened", session: { id: m.id, agent: m.agent, cwd: `~/.worktrees/web/${m.worktree.name}`, pid: 1, startedAt: Date.now(), taskId: m.taskId } });
      say({ type: "task.started", taskId: m.taskId, repo: REPO, repoDir: "~/src/web", base: "main", project: REPO });
    }
    if (m.type === "session.kill") say({ type: "session.ended", end: { id: m.id, cause: "killed", code: null, signal: null, detail: null, at: Date.now(), lastOutput: [], by: null } });
    if (m.type === "task.cleanup") r.cleanups.push(m);
  };
  say({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
  say({ type: "health", health: { cpu: 5, cores: 10, load1: 0.5, memUsed: 8e9, memTotal: 32e9, diskUsed: 2e11, diskTotal: 1e12, uptime: 1000, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] } });
  return r;
}

// ---- an admin saves the scripts; apps see them ----
const admin = await app(token);
const member = await app(await tokenFor(`mate${Date.now() % 10000}`));
if (admin.snapshot.me.role !== "admin") throw new Error(`the dev login is ${admin.snapshot.me.role}, not admin`);
if (!Array.isArray(admin.snapshot.scripts)) throw new Error("the snapshot has no scripts list");
if (!admin.snapshot.repos.some((r) => r.name === REPO)) {
  admin.send({ type: "repos.add", name: REPO });
  await admin.wait(`${REPO} added`, () => admin.repos.some((r) => r.name === REPO));
}
admin.send({ type: "repos.scripts.set", repo: REPO, scripts: SCRIPTS });
const saved = await admin.wait("repos.updated with the scripts", () => admin.scripts?.find((s) => s.repo === REPO && same(s.scripts, SAVED)));
if (saved.updatedBy !== admin.snapshot.me.login || !(saved.updatedAt > 0)) throw new Error(`saved as ${JSON.stringify(saved)}`);
step(`admin saved ${REPO}'s scripts: ${JSON.stringify(saved.scripts)} (trimmed, blank teardown dropped), by ${saved.updatedBy}`);
await member.wait("the member's repos.updated", () => member.scripts?.some((s) => s.repo === REPO && same(s.scripts, SAVED)));
step("the member's app got the same repos.updated");

const fresh = await app(token);
if (!fresh.scripts.some((s) => s.repo === REPO && same(s.scripts, SAVED))) throw new Error(`the snapshot's scripts: ${JSON.stringify(fresh.scripts)}`);
fresh.feed.close();
step("a new snapshot carries them");

member.send({ type: "repos.scripts.set", repo: REPO, scripts: { setup: "rm -rf ~" } });
await pause(1000);
const said = member.errors.shift();
if (!said || !/Only admins/.test(said)) throw new Error(`a member's repos.scripts.set wasn't refused (got ${JSON.stringify(said)})`);
step(`a member's repos.scripts.set refused: "${said}"`);
for (const [what, msg, pattern] of [
  ["a command over 4 KB", { type: "repos.scripts.set", repo: REPO, scripts: { setup: "x".repeat(4097) } }, /4 KB/],
  ["a timeout of 0", { type: "repos.scripts.set", repo: REPO, scripts: { setup: "true", timeoutSecs: 0 } }, /timeout/],
  ["a repo not in the list", { type: "repos.scripts.set", repo: "acme/nowhere", scripts: { setup: "true" } }, /isn't one of the org's repos/],
]) {
  admin.send(msg);
  await pause(1000);
  const got = admin.errors.shift();
  if (!got || !pattern.test(got)) throw new Error(`${what} wasn't refused (got ${JSON.stringify(got)})`);
  step(`${what} refused: "${got}"`);
}
if (!admin.scripts.some((s) => s.repo === REPO && same(s.scripts, SAVED))) throw new Error("a refused save changed the scripts");

// ---- the runner gets them with the task, and at cleanup ----
const fake = await runner(`scripts-${Date.now() % 100000}`);
await admin.wait("the runner", () => admin.machines.some((m) => m.id === fake.id && m.online));
for (const m of admin.machines.filter((x) => x.id !== fake.id && x.owner === admin.snapshot.me.login)) {
  admin.send({ type: "machine.settings", machine: m.id, settings: { capacity: null, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: true, pausedUntil: null } });
}
admin.send({ type: "machine.settings", machine: fake.id, settings: { capacity: 2, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null } });
await pause(500);

const prefix = `RS${Date.now() % 1000}`;
admin.send({ type: "goal.save", goal: { id: "", name: `Scripts ${prefix}`, prefix, color: "#8B5CF6", summary: "Worktree scripts test", lead: "", repos: [REPO], base: "main" } });
const goal = await admin.wait("goal", () => admin.goals.find((g) => g.prefix === prefix));
admin.send({ type: "task.create", goal: goal.id, title: "Run the setup", brief: "Nothing.", shareable: false, plan: true, tickets: [], agent: "claude" });
const taskId = `${prefix}-1`;
const open = await admin.wait(`${taskId}'s session.open`, () => fake.opened.find((m) => m.taskId === taskId));
if (!same(open.task.scripts, SAVED) || open.task.repo !== REPO) throw new Error(`TaskStart: ${JSON.stringify(open.task)}`);
step(`${fake.id} got ${taskId}'s TaskStart with scripts ${JSON.stringify(open.task.scripts)}`);

fake.say({ type: "task.progress", taskId, text: "ran setup (bin/worktree-setup --fast) in 1.2s" });
await admin.wait("the progress line on the timeline", () => admin.tasks.get(taskId)?.events.some((e) => e.text === "ran setup (bin/worktree-setup --fast) in 1.2s"));
step("task.progress landed on the task's timeline");

admin.send({ type: "goal.archive", id: goal.id, archived: true, unfinished: "cleanup" });
const cleanup = await admin.wait(`${taskId}'s task.cleanup`, () => fake.cleanups.find((m) => m.taskId === taskId));
if (!same(cleanup.scripts, SAVED) || cleanup.repo !== REPO || cleanup.branch !== `agent/${taskId.toLowerCase()}`) throw new Error(`task.cleanup: ${JSON.stringify(cleanup)}`);
step(`archiving with cleanup sent task.cleanup for ${cleanup.branch} with scripts ${JSON.stringify(cleanup.scripts)}`);

fake.say({ type: "task.cleaned", taskId, ok: true, branchDeleted: false, message: "archived by bin/worktree-archive" });
await admin.wait("the cleanup on the timeline", () => admin.tasks.get(taskId)?.events.some((e) => e.text === "cleaned up: archived by bin/worktree-archive"));
step("task.cleaned's message landed on the timeline");

// ---- clearing every command removes them ----
admin.send({ type: "repos.scripts.set", repo: REPO, scripts: { create: " ", setup: "", teardown: null, archive: "" } });
await admin.wait("the scripts removed", () => admin.scripts && !admin.scripts.some((s) => s.repo === REPO));
step(`blank commands cleared ${REPO}'s scripts`);

for (const m of admin.machines.filter((x) => x.id !== fake.id && x.owner === admin.snapshot.me.login)) {
  admin.send({ type: "machine.settings", machine: m.id, settings: { capacity: null, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null } });
}
await pause(1000);
console.log("all repo scripts checks passed");
process.exit(0);
