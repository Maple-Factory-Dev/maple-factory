// Repo secrets, against `wrangler dev` and two talking-only runners (enrolled here, like
// test/fake-runner.mjs):
//   node server/test/e2e-secrets.mjs http://localhost:8788 <wrangler state dir>
// The state dir is what `--persist-to` names (scripts/dev-stack.sh with a MAPLE_DEV_INSTANCE keeps it
// in $TMPDIR/maple-dev-<instance>/state); the test reads OrgHub's and D1's SQLite there with sqlite3.
// Checks: an admin sets API_KEY on acme/web, and the snapshot and secrets.updated carry only names
// and metadata; a member's secrets.set is refused; OrgHub's row holds ciphertext, not the value; the
// audit rows name the secret, never its value. Then the machine a task on acme/web is assigned to
// gets its values, another machine asking with that task is refused (and without a task gets them
// for its owner's checkout), and a deleted secret is gone from the next reply.

import { execFileSync } from "node:child_process";
import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const [base = "http://localhost:8788", state] = process.argv.slice(2);
if (!state) throw new Error("usage: e2e-secrets.mjs <server> <wrangler state dir>");
const ws = base.replace(/^http/, "ws");
const tokenFor = async (as) => (await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json()).token;
const token = await tokenFor();
const auth = { authorization: `Bearer ${token}` };
const step = (text) => console.log(`✓ ${text}`);
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const REPO = "acme/web";
const VALUE = `sk-live-${crypto.randomUUID()}`;
const OTHER = `other-${crypto.randomUUID()}`;

/** An app connection: the snapshot, broadcasts and errors it's been sent. */
async function app(tok) {
  const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${tok}` } });
  const c = { feed, raw: [], errors: [], snapshot: null, tasks: new Map(), goals: [], machines: [], secrets: [], poke: null };
  feed.onmessage = (e) => {
    c.raw.push(e.data);
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") { c.snapshot = m; c.goals = m.goals; c.machines = m.machines; c.secrets = m.secrets; for (const t of m.tasks) c.tasks.set(t.id, t); }
    if (m.type === "goal.updated") c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "machine.updated") c.machines = [...c.machines.filter((x) => x.id !== m.machine.id), m.machine];
    if (m.type === "task.updated") c.tasks.set(m.task.id, m.task);
    if (m.type === "secrets.updated") c.secrets = m.secrets;
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

/** A runner that only talks: enrolls, says hello, and answers nothing but records what it's sent. */
async function runner(runnerId) {
  const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: auth })).json();
  const enrolled = await (await fetch(`${base}/runner/enroll`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code, runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake" }),
  })).json();
  const sock = new WebSocket(`${ws}/runner/connect?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
  await new Promise((r, j) => { sock.onopen = r; sock.onerror = j; });
  const r = { id: runnerId, opened: [], replies: new Map() };
  sock.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "session.open") r.opened.push(m.taskId);
    if (m.type === "secrets.reply") r.replies.set(m.reqId, m);
  };
  const say = (m) => sock.send(JSON.stringify(m));
  say({ type: "hello", runnerId, hostname: runnerId, os: "macos", arch: "arm64", version: "0.0.0-fake", sessions: [], ended: [] });
  say({ type: "health", health: { cpu: 5, cores: 10, load1: 0.5, memUsed: 8e9, memTotal: 32e9, diskUsed: 2e11, diskTotal: 1e12, uptime: 1000, battery: null, agents: [{ name: "claude", version: "2.1.0", loggedIn: true }] } });
  r.request = async (repo, taskId) => {
    const reqId = crypto.randomUUID();
    say({ type: "secrets.request", reqId, repo, taskId: taskId ?? null });
    for (let i = 0; i < 40 && !r.replies.has(reqId); i++) await pause(250);
    return r.replies.get(reqId) ?? (() => { throw new Error(`${runnerId}: no secrets.reply`); })();
  };
  return r;
}

const sqliteFiles = (dir) => readdirSync(dir).flatMap((f) => {
  const p = join(dir, f);
  return statSync(p).isDirectory() ? sqliteFiles(p) : p.endsWith(".sqlite") ? [p] : [];
});
const sql = (file, query) => execFileSync("sqlite3", ["-json", file, query], { encoding: "utf8" }).trim();
const rows = (file, query) => JSON.parse(sql(file, query) || "[]");

// ---- an admin sets a secret; apps see names only ----
const admin = await app(token);
const member = await app(await tokenFor(`mate${Date.now() % 10000}`));
if (admin.snapshot.me.role !== "admin") throw new Error(`the dev login is ${admin.snapshot.me.role}, not admin`);
if (!Array.isArray(admin.snapshot.secrets)) throw new Error("the snapshot has no secrets list");
if (!admin.snapshot.repos.some((r) => r.name === REPO)) {
  admin.send({ type: "repos.add", name: REPO });
  await admin.wait(`${REPO} added`, () => admin.raw.some((s) => s.includes('"repos.updated"') && s.includes(REPO)));
}
const before = admin.raw.length;
admin.send({ type: "secrets.set", repo: REPO, name: "API_KEY", value: VALUE });
admin.send({ type: "secrets.set", repo: REPO, name: "OTHER_TOKEN", value: OTHER });
const listed = await admin.wait("secrets.updated", () => {
  const s = admin.secrets.filter((x) => x.repo === REPO);
  return s.some((x) => x.name === "API_KEY") && s.some((x) => x.name === "OTHER_TOKEN") && s;
});
const apiKey = listed.find((x) => x.name === "API_KEY");
if (Object.keys(apiKey).sort().join() !== "name,repo,updatedAt,updatedBy") throw new Error(`a listed secret has ${Object.keys(apiKey)}`);
if (apiKey.updatedBy !== admin.snapshot.me.login) throw new Error(`updatedBy is ${apiKey.updatedBy}`);
await member.wait("the member's secrets.updated", () => member.secrets.some((x) => x.repo === REPO && x.name === "API_KEY"));
const leaked = [...admin.raw.slice(before), ...member.raw].filter((s) => s.includes(VALUE) || s.includes(OTHER));
if (leaked.length) throw new Error(`a value went to an app: ${leaked[0].slice(0, 200)}`);
step(`admin set API_KEY and OTHER_TOKEN on ${REPO}; broadcasts carry ${Object.keys(apiKey).join(", ")}, no value`);

const fresh = await app(token);
const snapRaw = fresh.raw.find((s) => s.includes('"snapshot"'));
if (!fresh.secrets.some((x) => x.repo === REPO && x.name === "API_KEY") || snapRaw.includes(VALUE)) throw new Error("the snapshot's secrets are wrong");
fresh.feed.close();
step("a new snapshot lists API_KEY by name, without its value");

for (const [what, msg, pattern] of [
  ["a member's secrets.set", { type: "secrets.set", repo: REPO, name: "API_KEY", value: "nope" }, /Only admins/],
  ["a member's secrets.delete", { type: "secrets.delete", repo: REPO, name: "API_KEY" }, /Only admins/],
]) {
  member.send(msg);
  await pause(1000);
  const said = member.errors.shift();
  if (!said || !pattern.test(said)) throw new Error(`${what} wasn't refused (got ${JSON.stringify(said)})`);
  step(`${what} refused: "${said}"`);
}
for (const [what, msg, pattern] of [
  ["a bad name", { type: "secrets.set", repo: REPO, name: "lower-case", value: "x" }, /isn't a usable name/],
  ["a repo not in the list", { type: "secrets.set", repo: "acme/nowhere", name: "API_KEY", value: "x" }, /isn't one of the org's repos/],
  ["a value over 32 KB", { type: "secrets.set", repo: REPO, name: "BIG", value: "x".repeat(32 * 1024 + 1) }, /32 KB/],
]) {
  admin.send(msg);
  await pause(1000);
  const said = admin.errors.shift();
  if (!said || !pattern.test(said)) throw new Error(`${what} wasn't refused (got ${JSON.stringify(said)})`);
  step(`${what} refused: "${said}"`);
}

// ---- at rest: ciphertext in OrgHub, no value in the audit ----
const files = sqliteFiles(state);
const hub = files.find((f) => { try { return sql(f, "SELECT name FROM sqlite_master WHERE name = 'secrets'") !== ""; } catch { return false; } })
  ?? (() => { throw new Error(`no OrgHub SQLite with a secrets table under ${state}`); })();
const row = rows(hub, `SELECT repo, name, length(iv) AS iv, hex(ciphertext) AS ct, updated_by FROM secrets WHERE repo = '${REPO}' AND name = 'API_KEY'`)[0];
if (!row || row.iv !== 12) throw new Error(`OrgHub's row: ${JSON.stringify(row)}`);
const plainHex = Buffer.from(VALUE).toString("hex").toUpperCase();
if (row.ct.includes(plainHex) || execFileSync("strings", [hub], { encoding: "utf8" }).includes(VALUE)) throw new Error("the value is in OrgHub's SQLite in the clear");
if (row.ct.length / 2 !== VALUE.length + 16) throw new Error(`ciphertext is ${row.ct.length / 2} bytes for a ${VALUE.length}-byte value`);
step(`OrgHub's row: ${row.repo} ${row.name}, 12-byte IV, ${row.ct.length / 2}-byte AES-GCM ciphertext (${row.ct.slice(0, 16)}…); the value isn't in the file`);

const d1 = files.find((f) => { try { return sql(f, "SELECT name FROM sqlite_master WHERE name = 'audit'") !== ""; } catch { return false; } })
  ?? (() => { throw new Error(`no D1 SQLite with an audit table under ${state}`); })();
const audits = () => rows(d1, "SELECT action, target, detail FROM audit WHERE action LIKE 'secret.%' ORDER BY at");
const setRows = audits().filter((a) => a.action === "secret.set" && a.target === REPO);
if (!setRows.some((a) => JSON.parse(a.detail).name === "API_KEY")) throw new Error(`no secret.set audit: ${JSON.stringify(audits())}`);
if (JSON.stringify(audits()).includes(VALUE) || JSON.stringify(audits()).includes(OTHER)) throw new Error("a value is in the audit");
step(`audit: ${setRows.length} secret.set rows for ${REPO}, e.g. ${setRows.at(-1).detail}; no values`);

// ---- runners: only the machine with the task gets the values ----
const near = await runner(`secrets-a-${Date.now() % 100000}`);
const far = await runner(`secrets-b-${Date.now() % 100000}`);
await admin.wait("both runners", () => [near.id, far.id].every((id) => admin.machines.some((m) => m.id === id && m.online)));
// Only `near` may take sessions, so the task lands there.
for (const m of admin.machines.filter((x) => x.id !== near.id && x.owner === admin.snapshot.me.login)) {
  admin.send({ type: "machine.settings", machine: m.id, settings: { capacity: null, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: true, pausedUntil: null } });
}
admin.send({ type: "machine.settings", machine: near.id, settings: { capacity: 2, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null } });
await pause(500);

const prefix = `SC${Date.now() % 1000}`;
admin.send({ type: "goal.save", goal: { id: "", name: `Secrets ${prefix}`, prefix, color: "#8B5CF6", summary: "Secrets test", lead: "", repos: [REPO], base: "main" } });
const goal = await admin.wait("goal", () => admin.goals.find((g) => g.prefix === prefix));
admin.send({ type: "task.create", goal: goal.id, title: "Use the API key", brief: "Read API_KEY.", shareable: false, plan: true, tickets: [], agent: "claude" });
const taskId = `${prefix}-1`;
await admin.wait(`${taskId} on ${near.id}`, () => admin.tasks.get(taskId)?.machine === near.id && near.opened.includes(taskId));
step(`${taskId} on ${REPO} is assigned to ${near.id}`);

let got = await near.request(REPO, taskId);
if (got.error || got.values?.API_KEY !== VALUE || got.values?.OTHER_TOKEN !== OTHER) throw new Error(`${near.id} got ${JSON.stringify({ ...got, values: Object.keys(got.values ?? {}) })}`);
step(`${near.id} (assigned ${taskId}) got ${Object.keys(got.values).sort().join(", ")} with the right values`);

const refused = await far.request(REPO, taskId);
if (refused.values || refused.code !== "forbidden") throw new Error(`${far.id} wasn't refused: ${JSON.stringify(refused)}`);
step(`${far.id} asking with ${taskId} refused: "${refused.error}" (${refused.code})`);

const wrongRepo = await near.request("acme/other", taskId);
if (wrongRepo.values) throw new Error(`${near.id} got another repo's secrets with ${taskId}`);
step(`${near.id} asking for acme/other with ${taskId} refused: "${wrongRepo.error}"`);

const own = await far.request(REPO);
if (own.values?.API_KEY !== VALUE) throw new Error(`${far.id}'s pull for its owner's checkout: ${JSON.stringify(own.error)}`);
step(`${far.id} without a task (secrets pull, its owner a member) got ${Object.keys(own.values).sort().join(", ")}`);

admin.send({ type: "secrets.delete", repo: REPO, name: "OTHER_TOKEN" });
await admin.wait("OTHER_TOKEN deleted", () => !admin.secrets.some((x) => x.repo === REPO && x.name === "OTHER_TOKEN"));
got = await near.request(REPO, taskId);
if (got.error || "OTHER_TOKEN" in got.values || got.values.API_KEY !== VALUE) throw new Error(`after the delete: ${JSON.stringify(Object.keys(got.values ?? {}))}`);
step(`deleted OTHER_TOKEN: the next reply has only ${Object.keys(got.values).join(", ")}`);

const pulled = audits().filter((a) => a.action === "secret.pulled");
const deleted = audits().filter((a) => a.action === "secret.deleted");
if (pulled.length < 3 || !deleted.some((a) => JSON.parse(a.detail).name === "OTHER_TOKEN")) throw new Error(`audit: ${JSON.stringify(audits().slice(-5))}`);
if (JSON.stringify(audits()).includes(VALUE) || JSON.stringify(audits()).includes(OTHER)) throw new Error("a value is in the audit");
step(`audit: secret.pulled ${pulled.at(-1).detail}; secret.deleted ${deleted.at(-1).detail}; no values`);

// Tidy up: the task, the leftover secret, and the other machines back on.
admin.send({ type: "task.cancel", id: taskId });
admin.send({ type: "secrets.delete", repo: REPO, name: "API_KEY" });
for (const m of admin.machines.filter((x) => x.id !== near.id && x.id !== far.id && x.owner === admin.snapshot.me.login)) {
  admin.send({ type: "machine.settings", machine: m.id, settings: { capacity: null, teamSlots: 0, lendIdle: false, loadCap: 0.85, paused: false, pausedUntil: null } });
}
await pause(1000);
console.log("all secrets checks passed");
process.exit(0);
