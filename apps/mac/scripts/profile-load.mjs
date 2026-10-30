// The factory side of scripts/profile.sh, against a local dev stack (scripts/dev-stack.sh):
//   node apps/mac/scripts/profile-load.mjs seed <base> <out.json>   # a goal of tasks with comments, and proven tasks
//   node apps/mac/scripts/profile-load.mjs load <base> <seconds>     # live updates for that long
// `seed` is idempotent: a factory that already has the Profile goal is left as it is, so every run
// profiles the same tasks. It writes {goal, tasks, proofs} (proofs: ids of tasks with a screenshot
// and video proof) to out.json. `load` streams what a busy factory sends: a task edit every 100ms
// (each one a task.updated to every app) and a teammate moving to another task every 250ms (each one
// a presence to every app). Edits flip titles back and forth, so the factory's size never changes.

import { execFileSync } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [mode, base = "http://localhost:8788", arg] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const here = dirname(fileURLToPath(import.meta.url));
const TASKS = 150;
const TEAMMATES = ["prof-ana", "prof-ben", "prof-cy", "prof-dee"];

const token = async (as) => (await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json());

// An app connection: the feed, kept up to date, and a way to wait on it.
async function app(bearer) {
  const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${bearer}` } });
  const c = { feed, tasks: new Map(), goals: [], errors: [], poke: null, ready: false };
  feed.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { c.ready = true; c.goals = m.goals; for (const t of m.tasks) c.tasks.set(t.id, t); }
    if (m.type === "goal.updated") c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "task.updated") c.tasks.set(m.task.id, m.task);
    if (m.type === "error") c.errors.push(m.message);
    c.poke?.();
  };
  await new Promise((r, j) => { feed.onopen = r; feed.onerror = j; });
  c.send = (m) => feed.send(JSON.stringify(m));
  c.wait = async (what, test, ms = 60000) => {
    const deadline = Date.now() + ms;
    for (;;) {
      const hit = test();
      if (hit) return hit;
      if (c.errors.length) throw new Error(`server said: ${c.errors.join("; ")}`);
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
      await new Promise((r) => { c.poke = r; setTimeout(r, 250); });
    }
  };
  c.send({ type: "subscribe" });
  await c.wait("the snapshot", () => c.ready);
  return c;
}

async function seed(out) {
  const { token: bearer, member } = await token();
  for (const login of TEAMMATES) await token(login);
  const me = await app(bearer);
  let goal = me.goals.find((g) => g.prefix === "PROF");
  if (!goal) {
    me.send({ type: "goal.save", goal: { id: "", name: "Profile", prefix: "PROF", color: "#14B8A6", summary: "Profiling load.", lead: "", repos: [], folder: "/tmp/profile-repo", base: "main" } });
    goal = await me.wait("the goal", () => me.goals.find((g) => g.prefix === "PROF"));
  }
  const ours = () => [...me.tasks.values()].filter((t) => t.goal === goal.id);
  for (let i = ours().length; i < TASKS; i++) {
    me.send({ type: "task.create", goal: goal.id, title: `Profiling task ${i + 1}`, brief: `A task to fill the board (${i + 1}).\n\n${"Some brief text. ".repeat(20)}`, shareable: false, plan: false, tickets: [] });
    await me.wait(`task ${i + 1}`, () => ours().length > i);
  }
  for (const task of ours().filter((t) => t.comments.length === 0)) {
    const n = Number(task.title.match(/\d+/)?.[0] ?? 0);
    me.send({ type: "task.comment", id: task.id, text: `Looked at this one; ${"more context here. ".repeat(6)}` });
    if (n % 5 === 0) {
      const teammate = await app((await token(TEAMMATES[n % TEAMMATES.length])).token);
      teammate.send({ type: "task.comment", id: task.id, text: `@${member.login} can you check this one?` });
      await teammate.wait("the mention", () => teammate.tasks.get(task.id)?.comments.length >= 2);
      teammate.feed.close();
    }
    await me.wait(`comments on ${task.id}`, () => me.tasks.get(task.id)?.comments.length >= 1);
  }
  // Tasks with a real screenshot and video proof, from e2e-proofs.mjs (it leaves its task proven).
  const proven = () => [...me.tasks.values()].filter((t) => t.doneWhen?.some((d) => d.evidence?.file));
  if (proven().length < 3) {
    const shot = join(dirname(out), "proof-shot.png");
    const clip = join(dirname(out), "proof-clip.mp4");
    if (!existsSync(shot)) execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=3200x2000", "-frames:v", "1", shot]);
    if (!existsSync(clip)) execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30", "-t", "8", "-pix_fmt", "yuv420p", clip]);
    for (let i = proven().length; i < 3; i++) {
      execFileSync("node", [join(here, "../../../server/test/e2e-proofs.mjs"), base, shot, clip], { stdio: "ignore" });
      await me.wait("the proven task", () => proven().length > i);
    }
  }
  writeFileSync(out, JSON.stringify({ goal: goal.name, tasks: ours().map((t) => t.id), proofs: proven().map((t) => t.id) }, null, 2));
  me.feed.close();
}

async function load(seconds) {
  const me = await app((await token()).token);
  const goal = me.goals.find((g) => g.prefix === "PROF");
  if (!goal) throw new Error("no Profile goal; run seed first");
  const ids = [...me.tasks.values()].filter((t) => t.goal === goal.id && t.state === "drafting").map((t) => t.id);
  const teammates = await Promise.all(TEAMMATES.map(async (login) => app((await token(login)).token)));
  const pick = (list, i) => list[(i * 7919) % list.length];
  let edits = 0, moves = 0;
  const edit = setInterval(() => {
    const id = pick(ids, edits);
    const title = me.tasks.get(id).title;
    me.send({ type: "task.edit", id, title: title.endsWith(" ·") ? title.slice(0, -2) : `${title} ·` });
    edits++;
  }, 100);
  const move = setInterval(() => {
    teammates[moves % teammates.length].send({ type: "presence", viewing: pick(ids, moves + 13) });
    moves++;
  }, 250);
  await new Promise((r) => setTimeout(r, seconds * 1000));
  clearInterval(edit);
  clearInterval(move);
  // Every title back to where it started, so the next run sees the same factory.
  for (const id of ids) {
    const title = me.tasks.get(id).title;
    if (title.endsWith(" ·")) me.send({ type: "task.edit", id, title: title.slice(0, -2) });
  }
  await new Promise((r) => setTimeout(r, 1000));
  console.log(`${edits} task edits, ${moves} presence moves in ${seconds}s`);
  for (const c of [me, ...teammates]) c.feed.close();
}

if (mode === "seed") await seed(arg);
else if (mode === "load") await load(Number(arg ?? 20));
else { console.error("usage: profile-load.mjs seed <base> <out.json> | load <base> <seconds>"); process.exit(2); }
process.exit(0);
