// Handing a goal to a new lead through goal.save, against `wrangler dev`:
//   node server/test/e2e-goal-lead.mjs http://localhost:8788
// Checks: the lead hands a goal to a member (goal.updated carries the new lead, and the old lead can
// no longer change its prompts); an admin changes the lead; a member who isn't its lead is refused; a
// login that hasn't signed in is refused; a save that keeps the lead works for anyone.

const [base = "http://localhost:8788"] = process.argv.slice(2);

async function connect(as) {
  const { token, member } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const c = { member, goals: null, errors: [] };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "snapshot") c.goals = m.goals;
    if (m.type === "goal.updated") c.goals = [...c.goals.filter((g) => g.id !== m.goal.id), m.goal];
    if (m.type === "error") c.errors.push(m.message);
  };
  c.send = (m) => ws.send(JSON.stringify(m));
  c.close = () => ws.close();
  await new Promise((r) => (ws.onopen = r));
  c.send({ type: "subscribe" });
  await wait("snapshot", () => c.goals);
  return c;
}
async function wait(what, test, ms = 10000) {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = test();
    if (hit) return hit;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
}
const step = (text) => console.log(`✓ ${text}`);
/** Sends a save and waits for its refusal. */
async function refused(c, goal, what) {
  const seen = c.errors.length;
  c.send({ type: "goal.save", goal });
  return wait(what, () => c.errors[seen]);
}

const admin = await connect();
if (admin.member.role !== "admin") throw new Error(`${admin.member.login} isn't an admin`);
const ana = await connect("mf208-ana");
const ben = await connect("mf208-ben");
const cal = await connect("mf208-cal");
step(`signed in as ${admin.member.login} (admin), ${ana.member.login}, ${ben.member.login} and ${cal.member.login} (members)`);

const prefix = `LEAD${Date.now() % 1000}`;
ana.send({ type: "goal.save", goal: { id: "", name: `Lead ${prefix}`, prefix, color: "#F59E0B", summary: "", lead: "", repos: [], folder: "/tmp/lead-test", base: null } });
let goal = await wait("goal", () => ana.goals.find((g) => g.prefix === prefix));
if (goal.lead !== ana.member.login) throw new Error(`a new goal's lead is ${goal.lead}, not its creator`);
step(`a new goal defaults to its creator: lead ${goal.lead}`);

// Anyone can save a goal when the lead stays as it is, and leaving the lead out keeps it.
cal.send({ type: "goal.save", goal: { ...goal, summary: "cal was here" } });
goal = await wait("cal's save", () => ana.goals.find((g) => g.id === goal.id && g.summary === "cal was here"));
cal.send({ type: "goal.save", goal: { ...goal, lead: "", summary: "no lead sent" } });
goal = await wait("save without a lead", () => ana.goals.find((g) => g.id === goal.id && g.summary === "no lead sent"));
if (goal.lead !== ana.member.login) throw new Error(`leaving the lead out changed it to ${goal.lead}`);
step(`a save that keeps the lead (or leaves it out) works for a non-lead: lead still ${goal.lead}`);

const msg = await refused(cal, { ...goal, lead: cal.member.login }, "cal's refusal");
if (!msg.includes("hand")) throw new Error(`unexpected refusal: ${msg}`);
step(`a member who isn't its lead can't take it over: "${msg}"`);

const unknown = await refused(ana, { ...goal, lead: "mf208-nobody" }, "unknown login's refusal");
if (!unknown.includes("hasn't signed in")) throw new Error(`unexpected refusal: ${unknown}`);
step(`a login that hasn't signed in is refused: "${unknown}"`);
if (ana.goals.find((g) => g.id === goal.id).lead !== ana.member.login) throw new Error("a refused save changed the lead");

ana.send({ type: "goal.save", goal: { ...goal, lead: ben.member.login.toUpperCase() } });
goal = await wait("handed to ben", () => cal.goals.find((g) => g.id === goal.id && g.lead === ben.member.login));
step(`the lead hands it to ${goal.lead} (typed in another case): goal.updated carries the new lead`);

const prompts = { planner: "ana's rule", builder: "", reviewer: "" };
const noPrompts = await refused(ana, { ...goal, prompts }, "old lead's prompts refusal");
step(`the old lead can no longer change its agent instructions: "${noPrompts}"`);
const noHandBack = await refused(ana, { ...goal, lead: ana.member.login }, "old lead's hand-back refusal");
step(`nor take it back: "${noHandBack}"`);

ben.send({ type: "goal.save", goal: { ...goal, prompts } });
goal = await wait("ben's prompts", () => ana.goals.find((g) => g.id === goal.id && g.prompts?.planner === prompts.planner));
step("the new lead can change its agent instructions");

admin.send({ type: "goal.save", goal: { ...goal, lead: cal.member.login } });
goal = await wait("admin's change", () => ana.goals.find((g) => g.id === goal.id && g.lead === cal.member.login));
const fresh = await connect();
if (fresh.goals.find((g) => g.id === goal.id)?.lead !== cal.member.login) throw new Error("the snapshot lost the new lead");
fresh.close();
step(`an admin hands it to ${goal.lead}, in goal.updated and a fresh snapshot`);

admin.send({ type: "goal.archive", id: goal.id, archived: true });
await new Promise((r) => setTimeout(r, 300));
process.exit(0);
