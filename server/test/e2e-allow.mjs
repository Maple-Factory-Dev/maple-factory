// Who may sign in, against the fake GitHub: the account's members (or, on a personal account, its
// owner) and the logins in GITHUB_ALLOWED_LOGINS, and nobody else. Two phases, on the same D1:
//   node server/test/e2e-allow.mjs http://localhost:8788 <org> org|personal listed  <cookie file>
//   node server/test/e2e-allow.mjs http://localhost:8788 <org> org|personal removed <cookie file>
// `listed` runs with GITHUB_ALLOWED_LOGINS=friend on a fresh D1 (it finishes /setup first) and keeps
// friend's session in <cookie file>; `removed` runs after restarting with GITHUB_ALLOWED_LOGINS empty.
// The fake runs with --user <org> for personal, or --member <org>:alice for org.

import { readFileSync, writeFileSync } from "node:fs";

const [base, org, mode, phase, cookieFile] = process.argv.slice(2);
const personal = mode === "personal";
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const get = (path, cookie) => fetch(`${base}${path}`, { redirect: "manual", headers: cookie ? { cookie } : {} });
const cookieOf = (res, name) => res.headers.getSetCookie().map((c) => c.split(";")[0]).find((c) => c.startsWith(`maple_${name}=`) && c.length > name.length + 7);

/** Signs in through /auth/login and /auth/callback as <login>: the response, and the session cookie if any. */
async function signIn(login) {
  const start = await get("/auth/login");
  const state = new URL(start.headers.get("location")).searchParams.get("state");
  const res = await get(`/auth/callback?code=as-${login}&state=${encodeURIComponent(state)}`, cookieOf(start, "oauth"));
  return { status: res.status, session: cookieOf(res, "session"), message: res.status === 302 ? "" : await res.text() };
}
const me = async (session) => {
  const res = await get("/api/me", session);
  return res.status === 200 ? (await res.json()).member : null;
};

if (phase === "listed") {
  const setup = await get("/setup");
  const state = new URL((await setup.text()).match(/action="([^"]+)"/)[1].replace(/&amp;/g, "&")).searchParams.get("state");
  const made = await get(`/setup/github?code=app-${org}&state=${encodeURIComponent(state)}`, cookieOf(setup, "setup"));
  check(made.status === 302, `/setup makes the app (${made.status})`);

  if (personal) {
    const owner = await signIn(org);
    check(owner.status === 302 && (await me(owner.session))?.role === "admin", `${org}, the account's owner, signs in as admin`);
  } else {
    const alice = await signIn("alice");
    check(alice.status === 302 && (await me(alice.session))?.role === "member", `alice, a member of ${org}, signs in (${alice.status}${alice.message ? `: ${alice.message}` : ""})`);
  }
  const friend = await signIn("friend");
  check(friend.status === 302 && (await me(friend.session))?.role === "member", "friend, on the list, signs in as a member");
  const stranger = await signIn("stranger");
  check(stranger.status === 403, `stranger, on neither, is turned away (${stranger.status}: ${stranger.message})`);
  writeFileSync(cookieFile, friend.session ?? "");
} else {
  const session = readFileSync(cookieFile, "utf8");
  if (personal) check((await me(session)) === null, "off the list, friend's session stops working at once");
  else check((await me(session))?.login === "friend", "off the list, friend's session lasts until it expires, like an org member's");
  const again = await signIn("friend");
  check(again.status === 403, `and friend can't sign in again (${again.status})`);
}

process.exit(failures ? 1 : 0);
