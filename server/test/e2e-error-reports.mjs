// Settings › General's error reports toggle against `wrangler dev`:
//   node server/test/e2e-error-reports.mjs http://localhost:8788
// Checks: an admin's PUT /api/error-reports { on: false } stores SENTRY_DSN=off and /healthz says
// sentry: false; { on: true } turns it back; a member's PUT gets 403 and changes nothing; a body without
// `on` gets 400. Needs SENTRY_DSN unset in .dev.vars. (Each change is audited: error_reports.off/on.)

const [base = "http://localhost:8788"] = process.argv.slice(2);

async function signIn(as) {
  const { token, member } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const call = (method, body) => fetch(`${base}/api/error-reports`, {
    method,
    body: body === undefined ? undefined : JSON.stringify(body),
    headers: { authorization: `Bearer ${token}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
  });
  return { member, token, call };
}
const step = (text) => console.log(`✓ ${text}`);
const expect = async (res, status, what) => {
  const body = await res.text();
  if (res.status !== status) throw new Error(`${what}: expected ${status}, got ${res.status} ${body}`);
  return body;
};
const healthz = async () => (await (await fetch(`${base}/healthz`)).json()).sentry;

const admin = await signIn();
if (admin.member.role !== "admin") throw new Error(`${admin.member.login} isn't an admin`);
const member = await signIn("mf99-member");
step(`signed in as ${admin.member.login} (admin) and ${member.member.login} (${member.member.role})`);

const start = JSON.parse(await expect(await admin.call("GET"), 200, "GET"));
if (start.locked) throw new Error("SENTRY_DSN is set in .dev.vars; unset it to run this");
step(`GET /api/error-reports → ${JSON.stringify(start)}`);

const off = JSON.parse(await expect(await admin.call("PUT", { on: false }), 200, "admin's PUT off"));
if (off.on !== false || (await healthz()) !== false) throw new Error(`off: ${JSON.stringify(off)}, healthz sentry ${await healthz()}`);
step(`admin's PUT { on: false } → ${JSON.stringify(off)}; /healthz sentry: false`);

step(`member's PUT → 403: "${await expect(await member.call("PUT", { on: true }), 403, "member's PUT")}"`);
if ((await healthz()) !== false) throw new Error("a member's PUT turned reports back on");
step(`member's GET → ${await expect(await member.call("GET"), 200, "member's GET")}, and still off`);
step(`no on in the body → 400: "${await expect(await admin.call("PUT", { on: "yes" }), 400, "bad PUT")}"`);

const on = JSON.parse(await expect(await admin.call("PUT", { on: true }), 200, "admin's PUT on"));
if (on.on !== true || (await healthz()) !== true) throw new Error(`on: ${JSON.stringify(on)}, healthz sentry ${await healthz()}`);
step(`admin's PUT { on: true } → ${JSON.stringify(on)}; /healthz sentry: true`);

console.log("all good");
