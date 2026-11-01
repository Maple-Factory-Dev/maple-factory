// Linking a Slack account to a factory member (src/slack-links.ts): one-time codes (expiry, single use, relinking
// replaces), revoking a member drops the link, the link/unlink/mine matchers, and the `@Maple mine` summary.
import { test } from "node:test";
import assert from "node:assert/strict";
import { d1 } from "./d1.ts";
import { LINK_MS, linkOf, loginFor, peek, redeem, startLink, unlink, wantsLink, wantsMine, wantsUnlink } from "../src/slack-links.ts";
import { revokeMember } from "../src/auth.ts";
import { mineSummary } from "../src/factory/slack-status.ts";
import type { Goal, Task } from "../src/wire.ts";

const envWith = () => ({ DB: d1(), ORG: { idFromName: () => "org", get: () => ({ fetch: async () => new Response(null, { status: 204 }) }) } }) as any;

test("a code links its Slack account to the member who redeems it, once", async () => {
  const env = envWith();
  const code = await startLink(env, "T1", "U1", { name: "ana", teamName: "Acme" });
  assert.ok(code.length >= 30, "the code is long and random");
  const stored = env.DB.sql.prepare("SELECT hash FROM slack_link_codes").get() as { hash: string };
  assert.notEqual(stored.hash, code, "only the code's hash is stored");
  assert.deepEqual(await peek(env, code), { user: "U1", team: "T1", name: "ana", teamName: "Acme" });
  const linked = await redeem(env, code, "afomera");
  assert.equal(linked?.user, "U1");
  assert.equal(await loginFor(env, "T1", "U1"), "afomera");
  assert.equal((await linkOf(env, "afomera"))?.teamName, "Acme");
  assert.equal(await redeem(env, code, "afomera"), null, "a used code is refused");
  assert.equal(await redeem(env, code, "mallory"), null, "and refused for anyone else");
  assert.equal(await loginFor(env, "T1", "U1"), "afomera", "a refused code changes nothing");
});

test("expired and unknown codes are refused", async () => {
  const env = envWith();
  const now = Date.now();
  const code = await startLink(env, "T1", "U1", {}, now);
  assert.equal(await peek(env, code, now + LINK_MS), null);
  assert.equal(await redeem(env, code, "afomera", now + LINK_MS + 1), null);
  assert.equal(await redeem(env, "not-a-code", "afomera"), null);
  assert.equal(await redeem(env, "", "afomera"), null);
  assert.equal(await loginFor(env, "T1", "U1"), null);
});

test("relinking replaces: a member has one Slack account, a Slack account one member", async () => {
  const env = envWith();
  await redeem(env, await startLink(env, "T1", "U1"), "afomera");
  // The same member links a second Slack account: the first is dropped.
  await redeem(env, await startLink(env, "T1", "U2"), "afomera");
  assert.equal(await loginFor(env, "T1", "U1"), null);
  assert.equal(await loginFor(env, "T1", "U2"), "afomera");
  // Another member redeems a code for U2: it moves to them.
  await redeem(env, await startLink(env, "T1", "U2"), "ana");
  assert.equal(await loginFor(env, "T1", "U2"), "ana");
  assert.equal(await linkOf(env, "afomera"), null);
  // The same user id in another workspace is another account.
  assert.equal(await loginFor(env, "T2", "U2"), null);
});

test("unlinking by member or by Slack account, and revoking a member drops their link", async () => {
  const env = envWith();
  await redeem(env, await startLink(env, "T1", "U1"), "afomera");
  assert.equal(await unlink(env, { team: "T1", user: "U1" }), "afomera");
  assert.equal(await unlink(env, { team: "T1", user: "U1" }), null);
  await redeem(env, await startLink(env, "T1", "U1"), "afomera");
  assert.equal(await unlink(env, { login: "afomera" }), "afomera");
  await redeem(env, await startLink(env, "T1", "U1"), "afomera");
  await revokeMember(env, "afomera", "admin", false);
  assert.equal(await loginFor(env, "T1", "U1"), null);
});

test("wantsLink, wantsUnlink and wantsMine: the commands, not questions naming them", () => {
  for (const q of ["link", "Link.", "*link*", "link me", "link my account", "connect"]) assert.ok(wantsLink(q), q);
  for (const q of ["unlink", "unlink me", "disconnect", "link the docs page", "what does link do?", ""]) assert.ok(!wantsLink(q), q);
  for (const q of ["unlink", "Unlink!", "unlink my slack", "disconnect"]) assert.ok(wantsUnlink(q), q);
  for (const q of ["link", "unlink the two goals", "why unlink?"]) assert.ok(!wantsUnlink(q), q);
  for (const q of ["mine", "my tasks", "My tasks?", "what's waiting on me", "What’s waiting on me?", "whats on my plate", "show my tasks", "what's assigned to me"]) assert.ok(wantsMine(q), q);
  for (const q of ["status", "what's left on MF-171?", "is this mine to fix?", "my tasks are slow, why?"]) assert.ok(!wantsMine(q), q);
});

const goal = (id: string, lead: string): Goal => ({ id, name: id, prefix: id.toUpperCase(), color: "blue", summary: "", lead, repos: [`acme/${id}`], repo: `acme/${id}`, archived: false }) as Goal;
const task = (id: string, f: Partial<Task>): Task => ({ id, goal: "web", title: `Task ${id}`, state: "building", owner: "ana", approvals: [], approvalsNeeded: 1, reviews: [], reviewsNeeded: 1, ...f }) as Task;

test("mineSummary lists only the member's work: own tasks in flight, approvals and reviews waiting on them, hands to them", () => {
  const now = 10 * 60_000;
  const goals = [goal("web", "afomera"), goal("mob", "sam")];
  const tasks = [
    task("WEB-1", { owner: "afomera", worker: { startedAt: 5 * 60_000, agent: "claude" } as never }),
    task("WEB-2", { owner: "afomera", state: "merged" }),
    task("WEB-3", { owner: "ana", state: "awaitingApproval" }),
    task("WEB-4", { owner: "ana", state: "awaitingApproval", approvals: ["afomera"], approvalsNeeded: 2 }),
    task("WEB-5", { owner: "ana", state: "reviewing", pr: { number: 9 } as never }),
    task("MOB-1", { goal: "mob", owner: "sam", state: "awaitingApproval" }),
    task("MOB-2", { goal: "mob", owner: "sam", hand: { reason: "needsInput", summary: "Which icon?", assignee: "afomera", at: 0, options: [] } }),
    task("WEB-6", { owner: "ana" }),
  ];
  const said = mineSummary(tasks, goals, "afomera", now);
  assert.match(said, /^Your work, @afomera:/);
  assert.match(said, /\*Your tasks in flight\*\n• \*WEB-1\*[^\n]*building 5m/);
  assert.match(said, /\*Plans waiting on your approval\*\n• \*WEB-3\*/);
  assert.match(said, /\*PRs waiting on your review\*\n• \*WEB-5\*[^\n]*PR #9/);
  assert.match(said, /\*Waiting on you\*\n• \*MOB-2\*[^\n]*Which icon\?/);
  for (const id of ["WEB-2", "WEB-4", "MOB-1", "WEB-6"]) assert.ok(!said.includes(id), `${id} isn't afomera's to do`);
  assert.match(mineSummary(tasks, goals, "nobody", now), /Nothing is on your plate, @nobody/);
});
