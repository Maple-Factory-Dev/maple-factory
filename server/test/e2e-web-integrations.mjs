// The web Settings page's Integrations section (web/app/settings.js), against `wrangler dev`:
//   node server/test/e2e-web-integrations.mjs http://localhost:8788
// The server needs DEV_LOGIN (the admin here) and GITHUB_ALLOWED_LOGINS with bob in .dev.vars, so a made-up
// member (/dev/token?as=bob) can sign in without asking GitHub. The admin's integrations.save for Linear, as
// the page sends it (integrationSave), is answered by integrations.updated with the secret blank and Linear
// on, another tab hears it, and a fresh snapshot shows it; saving again with the secret blank keeps it. A
// member's save is refused and changes nothing.

import { integrationForm, integrationSave, integrationStatus } from "../web/app/settings.js";

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const stamp = Date.now() % 100000;
const SECRET = `whsec-web-${stamp}-do-not-leak`;
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const tokenFor = async (as) => {
  const res = await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" });
  if (!res.ok) throw new Error(`/dev/token: ${res.status} ${await res.text()} (is DEV_LOGIN set?)`);
  return res.json();
};

/** A feed connection, like the web app's: its snapshot and what it's been sent since. */
async function connect(token) {
  const feed = new WebSocket(`${ws}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const c = { seen: [], poke: null };
  feed.onmessage = (e) => { c.seen.push(JSON.parse(e.data)); c.poke?.(); };
  c.wait = async (what, test, ms = 10000) => {
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
/** A fresh connection's snapshot: what a reload of the page would show. */
const fresh = async (token) => { const c = await connect(token); c.close(); return c.snapshot; };
const linearOf = (list) => list?.find((i) => i.kind === "linear");
const ago = () => "just now";

const admin = await tokenFor();
const bob = await tokenFor("bob");
const a = await connect(admin.token);
const b = await connect(bob.token);
check(a.snapshot.me.role === "admin", `${admin.member.login} (DEV_LOGIN) is an admin`);
check(b.snapshot.me.role === "member", `bob is a member (${b.snapshot.me.role})`);
const before = linearOf(a.snapshot.integrations);
check(!!before, `the snapshot has Linear among ${a.snapshot.integrations?.map((i) => i.kind).join(", ")}`);

// The admin sets Linear up as the page does: the secret and a label typed into the form, Save and turn on.
const form = { ...integrationForm(before), webhookSecret: SECRET, label: `web-${stamp}` };
const saved = await a.ask(integrationSave(before, form, true), "integrations.updated", (m) => m.type === "integrations.updated");
const linear = linearOf(saved.integrations);
check(saved.type === "integrations.updated", `integrations.save → integrations.updated (${saved.type}${saved.message ? `: ${saved.message}` : ""})`);
check(linear?.enabled === true && linear.values.label === `web-${stamp}`, `Linear is on with label ${linear?.values.label}`);
check(linear?.values.webhookSecret === "", "its secret comes back blank: set, but not shown");
check(integrationStatus(linear, ago).text === "Connected · no events yet", `its status reads "${integrationStatus(linear, ago).text}"`);
check(linear?.updatedBy === admin.member.login, `saved by @${linear?.updatedBy}`);
const heard = await b.wait("bob's integrations.updated", () => b.seen.find((m) => m.type === "integrations.updated"));
check(linearOf(heard.integrations)?.enabled === true, "another tab hears integrations.updated live");

let snap = await fresh(admin.token);
check(linearOf(snap.integrations)?.values.label === `web-${stamp}` && linearOf(snap.integrations)?.enabled === true, "a fresh snapshot shows Linear on with its label");

// Saving again with the secret field left blank keeps the one that's set.
const again = await a.ask(integrationSave(linearOf(snap.integrations), integrationForm(linearOf(snap.integrations)), true), "integrations.updated again", (m) => m.type === "integrations.updated");
check(again.type === "integrations.updated" && linearOf(again.integrations)?.values.webhookSecret === "", `a save with the secret blank is taken (${again.type}${again.message ? `: ${again.message}` : ""}) and the secret is still set`);

// A member can't.
await b.wait("bob hearing the second save", () => b.seen.filter((m) => m.type === "integrations.updated").length >= 2);
const refused = await b.ask(integrationSave(linear, { ...integrationForm(linear), label: "bobs" }, false), "bob's refusal", (m) => m.type === "integrations.updated");
check(refused.type === "error", `bob's integrations.save is refused: "${refused.message}"`);
snap = await fresh(admin.token);
check(linearOf(snap.integrations)?.enabled === true && linearOf(snap.integrations)?.values.label === `web-${stamp}`, "and Linear is unchanged");

const leaked = [...a.seen, ...b.seen, snap].some((m) => JSON.stringify(m).includes(SECRET));
check(!leaked, "no message either tab was sent carries the secret");

a.close();
b.close();
if (failures) {
  console.log(`${failures} failed`);
  process.exit(1);
}
process.exit(0);
