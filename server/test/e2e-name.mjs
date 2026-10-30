// The factory's display name against `wrangler dev`:
//   node server/test/e2e-name.mjs http://localhost:8788
// Checks: an admin's PUT /api/name comes back as name.updated to everyone and in a fresh snapshot,
// trimmed; a member's PUT or DELETE gets 403; a name over 60 characters or a body without one gets 400
// and changes nothing; a blank name clears it, and so does DELETE /api/name.

const [base = "http://localhost:8788"] = process.argv.slice(2);

async function connect(as) {
  const { token, member } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const c = { member, token, seen: [], poke: null };
  feed.onmessage = (e) => {
    c.seen.push(JSON.parse(e.data));
    c.poke?.();
  };
  c.wait = async (what, test, ms = 15000) => {
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
  c.name = (method, body) =>
    fetch(`${base}/api/name`, {
      method,
      body: body === undefined ? undefined : JSON.stringify(body),
      headers: { authorization: `Bearer ${token}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
    });
  await new Promise((r) => (feed.onopen = r));
  feed.send(JSON.stringify({ type: "subscribe" }));
  await c.wait("snapshot", () => c.last("snapshot"));
  return c;
}
const step = (text) => console.log(`✓ ${text}`);
const expect = async (res, status, what) => {
  const body = await res.text();
  if (res.status !== status) throw new Error(`${what}: expected ${status}, got ${res.status} ${body}`);
  return body;
};
const snapshotName = async () => {
  const fresh = await connect();
  const name = fresh.last("snapshot").name;
  fresh.close();
  return name;
};

const admin = await connect();
if (admin.member.role !== "admin") throw new Error(`${admin.member.login} isn't an admin`);
const member = await connect("mf99-member");
step(`signed in as ${admin.member.login} (admin) and ${member.member.login} (${member.member.role})`);

const set = JSON.parse(await expect(await admin.name("PUT", { name: "  Andrea's   Factory " }), 200, "admin's PUT"));
if (set.name !== "Andrea's Factory") throw new Error(`PUT answered ${JSON.stringify(set)}`);
const updated = await member.wait("name.updated", () => member.seen.find((m) => m.type === "name.updated" && m.name === set.name));
step(`admin's PUT /api/name → 200 ${JSON.stringify(set)} (trimmed), and name.updated to everyone: ${JSON.stringify(updated)}`);

if ((await snapshotName()) !== "Andrea's Factory") throw new Error("snapshot name after PUT");
step(`a fresh snapshot has name = "Andrea's Factory"`);

step(`member's PUT → 403: "${await expect(await member.name("PUT", { name: "Mine now" }), 403, "member's PUT")}"`);
step(`member's DELETE → 403: "${await expect(await member.name("DELETE"), 403, "member's DELETE")}"`);
step(`61 characters → 400: "${await expect(await admin.name("PUT", { name: "x".repeat(61) }), 400, "long PUT")}"`);
step(`no name in the body → 400: "${await expect(await admin.name("PUT", { title: "x" }), 400, "bodyless PUT")}"`);
if ((await snapshotName()) !== "Andrea's Factory") throw new Error("a refused PUT changed the name");
step(`the refused PUTs left the name alone`);

const sixty = JSON.parse(await expect(await admin.name("PUT", { name: "y".repeat(60) }), 200, "60-character PUT"));
if (sixty.name.length !== 60) throw new Error(`60 characters: ${JSON.stringify(sixty)}`);
step(`exactly 60 characters → 200`);

const blank = JSON.parse(await expect(await admin.name("PUT", { name: "   " }), 200, "blank PUT"));
if (blank.name !== null) throw new Error(`blank PUT answered ${JSON.stringify(blank)}`);
await member.wait("name.updated null after blank", () => member.seen.findLast((m) => m.type === "name.updated")?.name === null);
if ((await snapshotName()) != null) throw new Error("snapshot name after a blank PUT");
step(`a blank name → 200 { name: null }, name.updated { name: null }, snapshot name cleared`);

await expect(await admin.name("PUT", { name: "Andrea's Factory" }), 200, "PUT again");
await member.wait("name.updated again", () => member.seen.findLast((m) => m.type === "name.updated")?.name === "Andrea's Factory");
await expect(await admin.name("DELETE"), 200, "admin's DELETE");
await member.wait("name.updated null", () => member.seen.findLast((m) => m.type === "name.updated")?.name === null);
if ((await snapshotName()) != null) throw new Error("snapshot name after DELETE");
step(`admin's DELETE → name.updated { name: null }, snapshot name cleared`);

admin.close();
member.close();
console.log("all good");
process.exit(0);
