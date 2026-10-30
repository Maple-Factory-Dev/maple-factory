// Factory admins against the fake GitHub: an org owner makes a plain member admin, the grant takes at once
// and survives signing in again, and is taken back; who may change it is checked, and nobody who has left the
// org can be made admin.
//   node server/test/e2e-admins.mjs http://localhost:8788 [fake GitHub URL]
// The fake runs with --owner acme:alice --member acme:bob --member acme:carol --member acme:dave --installed acme/greeter;
// the server with GITHUB_ORG=acme, GITHUB_API_URL pointing at the fake, the GitHub App's id, key, client id/secret
// and SESSION_SECRET set (or /setup done), no DEV_LOGIN, on a fresh local D1.

const [base = "http://localhost:8788", gh = "http://localhost:18803"] = process.argv.slice(2);
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const get = (path, cookie) => fetch(`${base}${path}`, { redirect: "manual", headers: cookie ? { cookie } : {} });
const cookieOf = (res, name) => res.headers.getSetCookie().map((c) => c.split(";")[0]).find((c) => c.startsWith(`maple_${name}=`) && c.length > name.length + 7);

/** Signs in through /auth/login and /auth/callback as <login>: their session cookie. */
async function signIn(login) {
  const start = await get("/auth/login");
  const state = new URL(start.headers.get("location")).searchParams.get("state");
  const res = await get(`/auth/callback?code=as-${login}&state=${encodeURIComponent(state)}`, cookieOf(start, "oauth"));
  if (res.status !== 302) throw new Error(`${login} couldn't sign in: ${res.status} ${await res.text()}`);
  return cookieOf(res, "session");
}
const me = async (session) => (await (await get("/api/me", session)).json()).member;

async function connect(session) {
  const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { cookie: session } });
  const c = { seen: [], poke: null };
  feed.onmessage = (e) => {
    c.seen.push(JSON.parse(e.data));
    c.poke?.();
  };
  c.send = (m) => feed.send(JSON.stringify(m));
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
    c.send(m);
    return c.wait(what, () => c.seen.slice(from).find((x) => x.type === "error" || test(x)));
  };
  c.close = () => feed.close();
  await new Promise((r) => (feed.onopen = r));
  c.send({ type: "subscribe" });
  c.snapshot = await c.wait("snapshot", () => c.seen.find((m) => m.type === "snapshot"));
  return c;
}
const memberIn = (msg, login) => msg?.type === "members.updated" ? msg.members.find((m) => m.login === login) : null;

const [aliceSession, bobSession, carolSession] = [await signIn("alice"), await signIn("bob"), await signIn("carol")];
await signIn("dave");
await fetch(`${gh}/_leave`, { method: "POST", body: JSON.stringify({ org: "acme", login: "dave" }) });
const alice = await connect(aliceSession);
const bob = await connect(bobSession);
const carol = await connect(carolSession);
check(alice.snapshot.me.role === "admin" && alice.snapshot.me.adminSource === "github", `alice, an owner of acme, is admin from GitHub (${JSON.stringify(alice.snapshot.me)})`);
check(bob.snapshot.me.role === "member" && !bob.snapshot.me.adminSource, `bob, a member of acme, is a member (${bob.snapshot.me.role})`);
check(alice.snapshot.members.length === 4, `everyone who has signed in is listed: ${alice.snapshot.members.map((m) => `${m.login} (${m.role})`).join(", ")}`);

const before = await bob.ask({ type: "prompts.save", prompts: { planner: "bob, before", builder: "", reviewer: "" } }, "bob's refusal", () => false);
check(before.type === "error", `before the grant, bob's prompts.save is refused: "${before.message}"`);

const denied = await carol.ask({ type: "admins.grant", login: "carol" }, "carol's refusal", (m) => m.type === "members.updated");
check(denied.type === "error", `carol, not an admin, can't grant: "${denied.message}"`);

const left = await alice.ask({ type: "admins.grant", login: "dave" }, "dave's refusal", (m) => m.type === "members.updated");
check(left.type === "error", `dave has left acme, so he can't be made admin: "${left.message}"`);

const granted = await alice.ask({ type: "admins.grant", login: "bob" }, "the grant", (m) => memberIn(m, "bob"));
const grantedBob = memberIn(granted, "bob");
check(grantedBob?.role === "admin" && grantedBob.adminSource === "granted" && grantedBob.adminGrantedBy === "alice", `alice grants bob: members.updated says ${JSON.stringify(grantedBob)}`);
const seenByCarol = await carol.wait("carol's members.updated", () => memberIn(carol.seen.findLast((m) => m.type === "members.updated"), "bob"));
check(seenByCarol.role === "admin", "everyone else's apps hear it too");
const again = await alice.ask({ type: "admins.grant", login: "bob" }, "the second grant", (m) => m.type === "members.updated");
check(again.type === "error", `granting him again is refused: "${again.message}"`);

const stamp = `bob's rule ${Date.now() % 100000}`;
const saved = await bob.ask({ type: "prompts.save", prompts: { planner: stamp, builder: "", reviewer: "" } }, "bob's save", (m) => m.type === "prompts.updated");
check(saved.type === "prompts.updated" && saved.prompts.planner === stamp, `bob's next message, on the same connection, works as an admin (${saved.type}${saved.message ? `: ${saved.message}` : ""})`);

const owner = await bob.ask({ type: "admins.revoke", login: "alice" }, "revoking alice", (m) => m.type === "members.updated");
check(owner.type === "error", `bob can't revoke alice, a GitHub owner: "${owner.message}"`);
const self = await bob.ask({ type: "admins.revoke", login: "bob" }, "bob revoking himself", (m) => m.type === "members.updated");
check(self.type === "error", `bob can't revoke himself: "${self.message}"`);

bob.close();
const rotated = await signIn("bob");
const bobAgain = await me(rotated);
check(bobAgain.role === "admin" && bobAgain.adminGrantedBy === "alice", `bob signs out and in again and is still admin (${JSON.stringify(bobAgain)})`);
const bob2 = await connect(rotated);
check(bob2.snapshot.me.role === "admin", "and his fresh snapshot says so");

const revoked = await alice.ask({ type: "admins.revoke", login: "bob" }, "the revoke", (m) => memberIn(m, "bob")?.role === "member");
check(memberIn(revoked, "bob")?.role === "member" && !memberIn(revoked, "bob").adminSource, `alice revokes bob: ${JSON.stringify(memberIn(revoked, "bob"))}`);
const after = await bob2.ask({ type: "prompts.save", prompts: { planner: "bob, after", builder: "", reviewer: "" } }, "bob's refusal", (m) => m.type === "prompts.updated");
check(after.type === "error", `bob's admin rights end at once: "${after.message}"`);
check((await me(rotated)).role === "member", "and /api/me says member");

for (const c of [alice, carol, bob2]) c.close();
process.exit(failures ? 1 : 0);
