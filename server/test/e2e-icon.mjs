// The factory's icon against `wrangler dev`:
//   node server/test/e2e-icon.mjs http://localhost:8788
// Checks: an admin's PUT /api/icon comes back as icon.updated to everyone and in a fresh snapshot, and
// /icon/<id> serves it without signing in; a member's PUT gets 403; a non-image or an image over 2 MB
// gets 400; DELETE /api/icon clears it to null (and the old image is gone).

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
  c.icon = (method, body, type = "image/png") =>
    fetch(`${base}/api/icon`, { method, body, headers: { authorization: `Bearer ${token}`, ...(body ? { "content-type": type } : {}) } });
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

// A 1×1 PNG, and one padded past 2 MB (a valid header, so only the size is wrong).
const png = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));
const big = new Uint8Array(2 * 1024 * 1024 + 1);
big.set(png);

const admin = await connect();
if (admin.member.role !== "admin") throw new Error(`${admin.member.login} isn't an admin`);
const member = await connect("mf94-member");
step(`signed in as ${admin.member.login} (admin) and ${member.member.login} (${member.member.role})`);

const set = JSON.parse(await expect(await admin.icon("PUT", png), 200, "admin's PUT"));
if (!/^\/icon\/[0-9a-f-]{36}$/.test(set.icon)) throw new Error(`PUT answered ${JSON.stringify(set)}`);
const updated = await member.wait("icon.updated", () => member.seen.find((m) => m.type === "icon.updated" && m.icon === set.icon));
step(`admin's PUT /api/icon → 200 ${set.icon}, and icon.updated to everyone: ${JSON.stringify(updated)}`);

let fresh = await connect();
if (fresh.last("snapshot").icon !== set.icon) throw new Error(`snapshot icon: ${fresh.last("snapshot").icon}`);
fresh.close();
step(`a fresh snapshot has icon = ${set.icon}`);

const served = await fetch(`${base}${set.icon}`);
const bytes = new Uint8Array(await served.arrayBuffer());
if (served.status !== 200 || served.headers.get("content-type") !== "image/png" || bytes.length !== png.length) throw new Error(`GET ${set.icon}: ${served.status} ${served.headers.get("content-type")} ${bytes.length}`);
step(`GET ${set.icon} without signing in → 200 image/png, ${bytes.length} bytes, ${served.headers.get("cache-control")}`);

step(`member's PUT → 403: "${await expect(await member.icon("PUT", png), 403, "member's PUT")}"`);
step(`member's DELETE → 403: "${await expect(await member.icon("DELETE"), 403, "member's DELETE")}"`);
step(`a text file → 400: "${await expect(await admin.icon("PUT", new TextEncoder().encode("not an image"), "text/plain"), 400, "text PUT")}"`);
step(`a PNG over 2 MB → 400: "${await expect(await admin.icon("PUT", big), 400, "big PUT")}"`);
fresh = await connect();
if (fresh.last("snapshot").icon !== set.icon) throw new Error("a refused upload changed the icon");
fresh.close();
step(`the refused uploads left the icon alone`);

const second = JSON.parse(await expect(await admin.icon("PUT", png), 200, "second PUT"));
if (second.icon === set.icon) throw new Error("a new upload kept the old link");
await expect(await fetch(`${base}${set.icon}`), 404, "the replaced image");
step(`a second upload gets a new link ${second.icon}; the old one is gone (404)`);

await expect(await admin.icon("DELETE"), 200, "admin's DELETE");
await member.wait("icon.updated null", () => member.seen.findLast((m) => m.type === "icon.updated")?.icon === null);
fresh = await connect();
if (fresh.last("snapshot").icon !== null) throw new Error(`snapshot icon after DELETE: ${fresh.last("snapshot").icon}`);
fresh.close();
await expect(await fetch(`${base}${second.icon}`), 404, "the removed image");
step(`admin's DELETE → icon.updated { icon: null }, snapshot icon = null, image gone`);

admin.close();
member.close();
console.log("all good");
process.exit(0);
