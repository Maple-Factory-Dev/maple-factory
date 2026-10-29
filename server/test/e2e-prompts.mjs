// The org's and a goal's prompt additions against `wrangler dev` and a real runner whose agents.toml
// has the `scripted` agent, wrapped so it writes the prompt it was given to <prompt log> first:
//   node server/test/e2e-prompts.mjs http://localhost:8788 <repo folder> <prompt log>
// Checks: an admin's prompts.save comes back as prompts.updated and in a fresh snapshot; a member's
// prompts.save, and a member's change to a goal's prompts when someone else leads it, are refused; a
// planner session is sent both the org's and the goal's planning text.

import { existsSync, readFileSync, rmSync } from "node:fs";

const [base = "http://localhost:8788", folder, log] = process.argv.slice(2);
if (!folder || !log) throw new Error("usage: e2e-prompts.mjs <server> <repo folder> <prompt log>");

async function connect(as) {
  const { token, member } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const c = { member, seen: [], errors: [], poke: null };
  feed.onmessage = (e) => {
    const m = JSON.parse(e.data);
    c.seen.push(m);
    if (m.type === "error") c.errors.push(m.message);
    c.poke?.();
  };
  c.send = (m) => feed.send(JSON.stringify(m));
  c.wait = async (what, test, ms = 30000) => {
    const deadline = Date.now() + ms;
    for (;;) {
      const hit = test();
      if (hit) return hit;
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
      await new Promise((r) => { c.poke = r; setTimeout(r, 250); });
    }
  };
  c.last = (type) => c.seen.findLast((m) => m.type === type);
  c.close = () => feed.close();
  await new Promise((r) => (feed.onopen = r));
  c.send({ type: "subscribe" });
  await c.wait("snapshot", () => c.last("snapshot"));
  return c;
}
const step = (text) => console.log(`✓ ${text}`);

const admin = await connect();
if (admin.member.role !== "admin") throw new Error(`${admin.member.login} isn't an admin`);
const member = await connect(`mf53-member`);
step(`signed in as ${admin.member.login} (admin) and ${member.member.login} (${member.member.role})`);

const stamp = Date.now() % 100000;
const org = { planner: `  Org planning rule ${stamp}: name the feature flag.  `, builder: `Org building rule ${stamp}`, reviewer: `Org review rule ${stamp}` };
admin.send({ type: "prompts.save", prompts: org });
const updated = await member.wait("prompts.updated", () => member.seen.find((m) => m.type === "prompts.updated" && m.prompts.builder === org.builder));
step(`admin's prompts.save → prompts.updated to everyone: ${JSON.stringify(updated.prompts)}`);
const fresh = await connect();
const snap = fresh.last("snapshot").prompts;
if (snap.planner !== org.planner.trim() || snap.reviewer !== org.reviewer) throw new Error(`snapshot prompts: ${JSON.stringify(snap)}`);
step(`a fresh snapshot has them (trimmed): planner = "${snap.planner}"`);
fresh.close();

member.send({ type: "prompts.save", prompts: { planner: "member was here", builder: "", reviewer: "" } });
const refused = await member.wait("member's error", () => member.errors.at(-1));
step(`member's prompts.save is refused: "${refused}"`);
const after = await connect();
if (after.last("snapshot").prompts.planner !== org.planner.trim()) throw new Error("the member's save landed");
after.close();

const prefix = `PR${stamp % 1000}`;
const goalPlanning = `Goal planning rule ${stamp}: keep it behind /beta.`;
admin.send({
  type: "goal.save",
  goal: { id: "", name: `Prompts ${prefix}`, prefix, color: "#7C3AED", summary: "Prompt additions", lead: admin.member.login, folder, base: "main", repos: [], prompts: { planner: goalPlanning, builder: "", reviewer: "" } },
});
let goal = await admin.wait("goal", () => admin.seen.findLast((m) => m.type === "goal.updated" && m.goal.prefix === prefix)?.goal);
step(`admin made goal ${goal.name} (lead ${goal.lead}) with planning text: "${goal.prompts.planner}"`);

member.errors.length = 0;
member.send({ type: "goal.save", goal: { ...goal, prompts: { ...goal.prompts, planner: "member rewrote it" } } });
const goalRefused = await member.wait("member's goal error", () => member.errors.at(-1));
step(`member's edit to the goal's prompts is refused: "${goalRefused}"`);
member.errors.length = 0;
member.send({ type: "goal.save", goal: { ...goal, summary: "Renamed by a member" } });
goal = await admin.wait("member's other edit", () => admin.seen.findLast((m) => m.type === "goal.updated" && m.goal.id === goal.id && m.goal.summary === "Renamed by a member")?.goal);
if (goal.prompts.planner !== goalPlanning || member.errors.length) throw new Error(`goal prompts after a member's edit: ${JSON.stringify(goal.prompts)} ${member.errors}`);
step(`a member's edit that leaves the prompts alone still saves, prompts kept`);
member.close();

if (existsSync(log)) rmSync(log);
admin.send({ type: "task.create", goal: goal.id, title: "Add a greeting", brief: "Add hello.txt with a greeting.", shareable: false, plan: true, tickets: [], agent: "scripted" });
await admin.wait("the planner's prompt", () => existsSync(log) && readFileSync(log, "utf8").includes("You are the planner"), 90000);
const prompt = readFileSync(log, "utf8");
const lines = prompt.split("\n");
const show = (heading) => lines.slice(lines.indexOf(heading), lines.indexOf(heading) + 2).join(" ⏎ ");
for (const want of ["## Org instructions", org.planner.trim(), "## Goal instructions", goalPlanning]) if (!prompt.includes(want)) throw new Error(`the planner's prompt lacks ${want}`);
if (prompt.indexOf(org.planner.trim()) > prompt.indexOf(goalPlanning)) throw new Error("goal's text came before the org's");
if (prompt.includes(org.builder) || prompt.includes(org.reviewer)) throw new Error("the planner got another role's text");
step(`the planner session's prompt has: ${show("## Org instructions")}`);
step(`  then: ${show("## Goal instructions")}`);
step(`  and neither the builder's nor the reviewer's text`);
admin.close();
console.log("all good");
process.exit(0);
