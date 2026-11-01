// Pausing a machine from the web Machines page (web/app/machines.js builds the messages), against `wrangler dev`:
//   node server/test/e2e-web-machine-pause.mjs http://localhost:8788
// The server needs DEV_LOGIN (an admin) and GITHUB_ALLOWED_LOGINS with bob and owner315 in .dev.vars. A fake
// runner enrolls for owner315, who gives it slots and caps; then pauses it for new work for an hour, pauses
// everything, and resumes, each with the exact machine.settings the page sends. Each shows in the live
// machine.updated and a fresh snapshot with slots and caps unchanged. bob (a member) can't pause it; the admin can.

import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { canManage, machineStatus, pauseSettings, pauseUntil, resumeSettings } from "../web/app/machines.js";

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const owner = "owner315";
const id = `pause-${Date.now() % 100000}`;
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const tokenFor = async (as) => {
  const res = await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" });
  if (!res.ok) throw new Error(`/dev/token: ${res.status} ${await res.text()} (is DEV_LOGIN set?)`);
  return res.json();
};

async function connect(token) {
  const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const c = { seen: [], poke: null };
  feed.onmessage = (e) => { c.seen.push(JSON.parse(e.data)); c.poke?.(); };
  c.wait = async (what, test, ms = 15000) => {
    const deadline = Date.now() + ms;
    for (;;) {
      const hit = test();
      if (hit) return hit;
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
      await new Promise((r) => { c.poke = r; setTimeout(r, 200); });
    }
  };
  /** Sends `m` and waits for the first message after it that `test` takes, or an error. */
  c.ask = async (m, what, test) => {
    const from = c.seen.length;
    feed.send(JSON.stringify(m));
    return c.wait(what, () => c.seen.slice(from).find((x) => x.type === "error" || test(x)));
  };
  c.close = () => feed.close();
  await new Promise((r, j) => { feed.onopen = r; feed.onerror = j; });
  feed.send(JSON.stringify({ type: "subscribe" }));
  c.snapshot = await c.wait("snapshot", () => c.seen.find((m) => m.type === "snapshot"));
  return c;
}
const fresh = async (token) => { const c = await connect(token); c.close(); return c.snapshot.machines.find((m) => m.id === id); };
const updated = (test) => (m) => m.type === "machine.updated" && m.machine.id === id && test(m.machine);

const runner = spawn("node", [join(dirname(fileURLToPath(import.meta.url)), "fake-runner.mjs"), base, id, "120", "20", owner], { stdio: "ignore" });
try {
  const admin = await tokenFor();
  const o = await tokenFor(owner);
  const bob = await tokenFor("bob");
  const a = await connect(o.token);
  let m = await a.wait(`${id} online`, () => [...a.seen].reverse().map((x) => x.type === "machine.updated" ? x.machine : x.type === "snapshot" ? x.machines.find((y) => y.id === id) : null).find((x) => x?.id === id && x.online));
  check(canManage(m, a.snapshot.me), `${owner} owns ${id} and gets the Pause control`);

  // Slots and caps of its own, so the pauses can be seen to leave them alone.
  const own = { capacity: 3, teamSlots: 1, lendIdle: true, loadCap: 0.6, paused: false, pausedUntil: null, pauseNew: false, sessionCap: 0.9, weeklyCap: 0.7, agentCaps: null, capsTeamOnly: true };
  m = (await a.ask({ type: "machine.settings", machine: id, settings: own }, "settings saved", updated((x) => x.settings?.teamSlots === 1))).machine;
  check(m?.settings?.loadCap === 0.6, "it has 1 team slot, a 60% load cap and 90%/70% plan caps");
  const kept = (s) => s.capacity === 3 && s.teamSlots === 1 && s.lendIdle === true && s.loadCap === 0.6 && s.sessionCap === 0.9 && s.weeklyCap === 0.7 && s.capsTeamOnly === true;
  const time = (ms) => new Date(ms).toISOString();

  // Pause new work for 1 hour.
  const until = pauseUntil("hour", Date.now());
  let r = await a.ask({ type: "machine.settings", machine: id, settings: pauseSettings(m, { scope: "new", until }) }, "new-work pause", updated((x) => x.settings?.paused));
  check(r.type === "machine.updated", `pause new work for 1h → machine.updated (${r.type}${r.message ? `: ${r.message}` : ""})`);
  m = r.machine;
  let st = machineStatus(m, Date.now(), { time });
  check(m.settings.pauseNew === true && m.settings.pausedUntil === until && kept(m.settings), `paused for new work until ${time(until)}, slots and caps unchanged`);
  check(st.label === "Paused for new work" && st.detail.startsWith(`until ${time(until)}`), `the card says "${st.label}" · "${st.detail}"`);
  let snap = await fresh(o.token);
  check(snap.settings.paused && snap.settings.pauseNew && snap.settings.pausedUntil === until && kept(snap.settings), "a fresh snapshot has the new-work pause");

  // bob, a member, can't pause someone else's machine.
  const b = await connect(bob.token);
  const bm = b.snapshot.machines.find((x) => x.id === id);
  check(bm && !canManage(bm, b.snapshot.me), "bob (a member) sees the card with no Pause control");
  const refused = await b.ask({ type: "machine.settings", machine: id, settings: pauseSettings(bm, { scope: "all", until: null }) }, "bob's refusal", updated((x) => x.settings?.pauseNew === false));
  check(refused.type === "error", `bob's pause is refused: "${refused.message}"`);
  b.close();
  snap = await fresh(o.token);
  check(snap.settings.pauseNew === true && snap.settings.pausedUntil === until, "and the pause is still the owner's new-work one");

  // Pause everything, until resumed.
  r = await a.ask({ type: "machine.settings", machine: id, settings: pauseSettings(m, { scope: "all", until: pauseUntil("resume", Date.now()) }), handOff: true }, "full pause", updated((x) => x.settings?.paused && !x.settings.pauseNew));
  check(r.type === "machine.updated", `pause everything → machine.updated (${r.type}${r.message ? `: ${r.message}` : ""})`);
  m = r.machine;
  st = machineStatus(m, Date.now(), { time });
  check(m.settings.pausedUntil == null && kept(m.settings), "paused until resumed, slots and caps unchanged");
  check(st.label === "Paused" && st.detail === "until resumed", `the card says "${st.label}" · "${st.detail}"`);
  snap = await fresh(o.token);
  check(snap.settings.paused && !snap.settings.pauseNew && kept(snap.settings), "a fresh snapshot has the full pause");

  // Resume.
  r = await a.ask({ type: "machine.settings", machine: id, settings: resumeSettings(m) }, "resume", updated((x) => !x.settings?.paused));
  check(r.type === "machine.updated", `resume → machine.updated (${r.type}${r.message ? `: ${r.message}` : ""})`);
  m = r.machine;
  st = machineStatus(m, Date.now(), { time });
  check(!m.settings.pauseNew && m.settings.pausedUntil == null && kept(m.settings), "resumed: no pausedUntil or pauseNew, slots and caps unchanged");
  check(st.kind === "idle" || st.kind === "working", `the card says "${st.label}"`);
  snap = await fresh(o.token);
  check(!snap.settings.paused && kept(snap.settings), "a fresh snapshot has it running again");

  // An admin manages every machine.
  const ad = await connect(admin.token);
  const am = ad.snapshot.machines.find((x) => x.id === id);
  check(ad.snapshot.me.role === "admin" && canManage(am, ad.snapshot.me), `${admin.member.login} (an admin) gets the Pause control on ${owner}'s machine`);
  r = await ad.ask({ type: "machine.settings", machine: id, settings: pauseSettings(am, { scope: "new", until: null }) }, "admin pause", updated((x) => x.settings?.paused));
  check(r.type === "machine.updated" && kept(r.machine.settings), `the admin's pause takes (${r.type}${r.message ? `: ${r.message}` : ""})`);
  r = await ad.ask({ type: "machine.settings", machine: id, settings: resumeSettings(r.machine) }, "admin resume", updated((x) => !x.settings?.paused));
  check(r.type === "machine.updated", "and so does their resume");
  ad.close();
  a.close();
} finally {
  runner.kill();
}
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);
