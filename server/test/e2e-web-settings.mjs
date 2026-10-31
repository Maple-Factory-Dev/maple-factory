// The web Settings page's messages (web/app/settings.js), against `wrangler dev`:
//   node server/test/e2e-web-settings.mjs http://localhost:8788
// The server needs DEV_LOGIN (the admin here) and GITHUB_ALLOWED_LOGINS with bob and carol in .dev.vars, so a
// made-up teammate (/dev/token?as=) can be made admin without asking GitHub. Each message the page sends as
// an admin (policy.save, prompts.save, repos.add/remove, repos.owners.set, secrets.set/delete, admins.grant/revoke)
// and PUT /api/name is answered by its *.updated, and a fresh connection's snapshot shows it; a member's
// policy.save, secrets.set and admins.grant are refused and change nothing.

const [base = "http://localhost:8788"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
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

const admin = await tokenFor();
const bob = await tokenFor("bob");
const carol = await tokenFor("carol");
const a = await connect(admin.token);
const b = await connect(bob.token);
check(a.snapshot.me.role === "admin", `${admin.member.login} (DEV_LOGIN) is an admin`);
check(b.snapshot.me.role === "member", `bob is a member (${b.snapshot.me.role})`);
const stamp = Date.now() % 100000;

// Merging & risk: auto-merge off for medium, numbers changed, the sensitive areas kept.
const before = a.snapshot.policy;
const policy = { ...before, autoMerge: { ...before.autoMerge, medium: !before.autoMerge.medium }, maxFiles: before.maxFiles + 1, scoutItems: (before.scoutItems ?? 3) % 10 + 1, autoFixMerges: !(before.autoFixMerges ?? true) };
const saved = await a.ask({ type: "policy.save", policy }, "policy.updated", (m) => m.type === "policy.updated");
check(saved.type === "policy.updated" && saved.policy.autoMerge.medium === policy.autoMerge.medium, `policy.save → policy.updated (${saved.type}${saved.message ? `: ${saved.message}` : ""})`);
const heard = await b.wait("bob's policy.updated", () => b.seen.find((m) => m.type === "policy.updated"));
check(heard.policy.maxFiles === policy.maxFiles, "another tab hears policy.updated live");
let snap = await fresh(admin.token);
check(JSON.stringify(snap.policy) === JSON.stringify(policy), `a fresh snapshot has the policy: medium auto-merge ${snap.policy.autoMerge.medium}, ${snap.policy.maxFiles} files, ${snap.policy.scoutItems} Scout items, areas ${snap.policy.areas.length}`);

// A member can't.
const refused = await b.ask({ type: "policy.save", policy: { ...policy, maxFiles: 99 } }, "bob's refusal", (m) => m.type === "policy.updated");
check(refused.type === "error", `bob's policy.save is refused: "${refused.message}"`);
check((await fresh(admin.token)).policy.maxFiles === policy.maxFiles, "and the policy is unchanged");

// Prompts.
const prompts = { planner: `Plan in small steps ${stamp}`, builder: "Run npm test.", reviewer: "" };
const p = await a.ask({ type: "prompts.save", prompts }, "prompts.updated", (m) => m.type === "prompts.updated");
check(p.type === "prompts.updated" && p.prompts.planner === prompts.planner, `prompts.save → prompts.updated (${p.type}${p.message ? `: ${p.message}` : ""})`);
check((await fresh(admin.token)).prompts?.planner === prompts.planner, "a fresh snapshot has the prompts");

// Repositories: add one by hand, approve another account, remove the repo.
const repo = `acme/settings-${stamp}`;
const added = await a.ask({ type: "repos.add", name: `https://github.com/${repo}.git` }, "repos.updated", (m) => m.type === "repos.updated" && m.repos.some((r) => r.name === repo));
check(added.type === "repos.updated", `repos.add ${repo} (given as a GitHub URL) → repos.updated (${added.type}${added.message ? `: ${added.message}` : ""})`);
snap = await fresh(admin.token);
check(snap.repos.find((r) => r.name === repo)?.source === "manual", "a fresh snapshot lists it, added by hand");
// repos.owners.set reads the GitHub App's repos again after it saves; without an app (local dev) that read
// answers with an error of its own, after the repos.updated, so it's waited for here and not taken for the next step's.
const noApp = (m) => m.type === "error" && /no GitHub App/.test(m.message);
const setOwners = async (list, test) => {
  const from = a.seen.length;
  const answer = await a.ask({ type: "repos.owners.set", owners: list }, "repos.updated with owners", (m) => m.type === "repos.updated" && test(m));
  if (!a.snapshot.githubApp) await a.wait("the re-read's answer", () => a.seen.slice(from).find(noApp)).catch(() => {});
  return answer;
};
const owners = await setOwners(["other-org", "someone"], (m) => m.repoOwners?.includes("other-org"));
check(owners.type === "repos.updated", `repos.owners.set → repos.updated (${JSON.stringify(owners.repoOwners ?? owners.message)})`);
check(JSON.stringify((await fresh(admin.token)).repoOwners) === JSON.stringify(["other-org", "someone"]), "a fresh snapshot has the approved accounts");
await setOwners([], (m) => !m.repoOwners?.length);

// Secrets: set one on the new repo (names only come back), replace it, delete it.
const value = `sk-${crypto.randomUUID()}`;
const set = await a.ask({ type: "secrets.set", repo, name: "API_KEY", value }, "secrets.updated", (m) => m.type === "secrets.updated" && m.secrets.some((s) => s.repo === repo));
check(set.type === "secrets.updated" && !JSON.stringify(set).includes(value), `secrets.set → secrets.updated, names only (${set.type}${set.message ? `: ${set.message}` : ""})`);
snap = await fresh(admin.token);
const listed = snap.secrets.find((s) => s.repo === repo && s.name === "API_KEY");
check(listed?.updatedBy === admin.member.login && !JSON.stringify(snap).includes(value), `a fresh snapshot lists API_KEY, set by ${listed?.updatedBy}, without its value`);
const memberSet = await b.ask({ type: "secrets.set", repo, name: "STOLEN", value: "x" }, "bob's refusal", (m) => m.type === "secrets.updated");
check(memberSet.type === "error", `bob's secrets.set is refused: "${memberSet.message}"`);
const replaced = await a.ask({ type: "secrets.set", repo, name: "API_KEY", value: `${value}-2` }, "secrets.updated again", (m) => m.type === "secrets.updated");
check(replaced.type === "secrets.updated" && replaced.secrets.filter((s) => s.repo === repo).length === 1, "setting it again replaces it (still one secret)");
const deleted = await a.ask({ type: "secrets.delete", repo, name: "API_KEY" }, "secrets.updated after delete", (m) => m.type === "secrets.updated" && !m.secrets.some((s) => s.repo === repo));
check(deleted.type === "secrets.updated", "secrets.delete → secrets.updated without it");
check(!(await fresh(admin.token)).secrets.some((s) => s.repo === repo), "a fresh snapshot doesn't list it");

const removed = await a.ask({ type: "repos.remove", name: repo }, "repos.updated without it", (m) => m.type === "repos.updated" && !m.repos.some((r) => r.name === repo));
check(removed.type === "repos.updated", `repos.remove → repos.updated without ${repo}`);
check(!(await fresh(admin.token)).repos.some((r) => r.name === repo), "a fresh snapshot doesn't list it");

// People: bob can't grant; the admin grants carol, she's admin in a fresh snapshot, and it's taken back.
const memberGrant = await b.ask({ type: "admins.grant", login: "bob" }, "bob's refusal", (m) => m.type === "members.updated");
check(memberGrant.type === "error", `bob's admins.grant is refused: "${memberGrant.message}"`);
const granted = await a.ask({ type: "admins.grant", login: "carol" }, "members.updated with carol", (m) => m.type === "members.updated" && m.members.find((x) => x.login === "carol")?.role === "admin");
const g = granted.members?.find((x) => x.login === "carol");
check(g?.role === "admin" && g.adminSource === "granted" && g.adminGrantedBy === admin.member.login, `admins.grant carol → members.updated (${JSON.stringify(g ?? granted.message)})`);
check((await fresh(carol.token)).me.role === "admin", "carol's fresh snapshot says admin");
const revoked = await a.ask({ type: "admins.revoke", login: "carol" }, "members.updated without carol's grant", (m) => m.type === "members.updated" && m.members.find((x) => x.login === "carol")?.role === "member");
check(revoked.type === "members.updated", "admins.revoke carol → members.updated, member again");
check((await fresh(carol.token)).me.role === "member", "carol's fresh snapshot says member");

// General: rename the factory, then clear it.
const named = await fetch(`${base}/api/name`, { method: "PUT", headers: { authorization: `Bearer ${admin.token}`, "content-type": "application/json" }, body: JSON.stringify({ name: `Settings ${stamp}` }) });
check(named.ok, `PUT /api/name → ${named.status}`);
const nameHeard = await a.wait("name.updated", () => a.seen.find((m) => m.type === "name.updated"));
check(nameHeard.name === `Settings ${stamp}` && (await fresh(admin.token)).name === `Settings ${stamp}`, "name.updated, and a fresh snapshot has the name");
const memberName = await fetch(`${base}/api/name`, { method: "PUT", headers: { authorization: `Bearer ${bob.token}`, "content-type": "application/json" }, body: JSON.stringify({ name: "Bob's" }) });
check(memberName.status === 403, `bob's PUT /api/name is refused (${memberName.status})`);
await fetch(`${base}/api/name`, { method: "DELETE", headers: { authorization: `Bearer ${admin.token}` } });

// Leave the policy and prompts as they were.
await a.ask({ type: "policy.save", policy: before }, "policy restored", (m) => m.type === "policy.updated");
await a.ask({ type: "prompts.save", prompts: a.snapshot.prompts ?? { planner: "", builder: "", reviewer: "" } }, "prompts restored", (m) => m.type === "prompts.updated");

a.close();
b.close();
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);
