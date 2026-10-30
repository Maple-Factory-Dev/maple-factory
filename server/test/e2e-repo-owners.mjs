// Repos from other GitHub accounts, against the fake GitHub (test/fake-github.mjs) with the app
// installed on the factory's own account, on another org, and on a stranger's account:
//   node server/test/fake-github.mjs --public-key app.pub.pem --installed afomera/maple-factory \
//     --installed maple-dev-factory/maple-factory --installed stranger/evil --user afomera --user stranger
//   node server/test/e2e-repo-owners.mjs http://localhost:8788 [fake GitHub URL] [org] [other] [stranger]
// The server needs GITHUB_ORG=<org> (default afomera), GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY,
// GITHUB_APP_SLUG, GITHUB_API_URL and, for a personal <org>, GITHUB_ALLOWED_LOGINS=mona (the member). Checks: the snapshot has the app's links and no other accounts;
// only <org>'s repos come in until an admin approves <other>; a member can't approve one; approving
// brings <other>'s repos in (and tells everyone), removing it takes them out; <stranger>'s repos never
// come in, and the factory never makes a token for its installation.

const [base = "http://localhost:8788", gh = "http://localhost:18803", org = "afomera", other = "maple-dev-factory", stranger = "stranger"] = process.argv.slice(2);

async function connect(as) {
  const { token, member } = await (await fetch(`${base}/dev/token${as ? `?as=${as}` : ""}`, { method: "POST" })).json();
  const feed = new WebSocket(`${base.replace(/^http/, "ws")}/client/connect`, { headers: { authorization: `Bearer ${token}` } });
  const c = { member, seen: [], poke: null };
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
  c.send = (m) => feed.send(JSON.stringify(m));
  c.close = () => feed.close();
  await new Promise((r, reject) => { feed.onopen = r; feed.onerror = () => reject(new Error(`${as ?? "the dev login"} couldn't connect`)); });
  c.send({ type: "subscribe" });
  await c.wait("snapshot", () => c.last("snapshot"));
  return c;
}
const step = (text) => console.log(`✓ ${text}`);
const names = (repos) => repos.map((r) => r.name.toLowerCase());
const owned = (repos, owner) => names(repos).filter((n) => n.startsWith(`${owner.toLowerCase()}/`));
/** The repos once a repos.updated after `n` messages says so. */
const reposAfter = (c, n, test) => c.wait("repos.updated", () => {
  const u = c.seen.slice(n).findLast((m) => m.type === "repos.updated");
  return u && test(u) && u;
});

const admin = await connect();
if (admin.member.role !== "admin") throw new Error(`the dev login is ${admin.member.role}, not admin`);
const snap = admin.last("snapshot");
const app = snap.githubApp;
if (JSON.stringify(snap.repoOwners) !== "[]") throw new Error(`repoOwners: ${JSON.stringify(snap.repoOwners)}`);
if (!app?.slug || !app.settingsUrl.endsWith(`/settings/apps/${app.slug}/advanced`) || app.installUrl !== `https://github.com/apps/${app.slug}/installations/new`) {
  throw new Error(`githubApp: ${JSON.stringify(app)}`);
}
step(`the snapshot has no other accounts, and the app's links: ${app.settingsUrl}, ${app.installUrl}`);

let n = admin.seen.length;
admin.send({ type: "repos.refresh" });
let u = await reposAfter(admin, n, (m) => owned(m.repos, org).length);
if (owned(u.repos, other).length || owned(u.repos, stranger).length) throw new Error(`before approving: ${names(u.repos)}`);
step(`only ${org}'s installation adds repos: ${names(u.repos).join(", ")}`);

const member = await connect("mona");
member.send({ type: "repos.owners.set", owners: [other] });
const refused = await member.wait("refusal", () => member.last("error"));
if (!/Only admins/.test(refused.message)) throw new Error(`member: ${refused.message}`);
step(`a member can't approve ${other}: "${refused.message}"`);

n = admin.seen.length;
admin.send({ type: "repos.owners.set", owners: ["not a login!"] });
const bad = await admin.wait("bad login", () => admin.seen.slice(n).find((m) => m.type === "error"));
step(`a login that isn't one is refused: "${bad.message}"`);

n = admin.seen.length;
const m0 = member.seen.length;
admin.send({ type: "repos.owners.set", owners: [`@${other}`, org, other.toUpperCase()] });
u = await reposAfter(admin, n, (m) => owned(m.repos, other).length);
if (JSON.stringify(u.repoOwners) !== JSON.stringify([other])) throw new Error(`repoOwners: ${JSON.stringify(u.repoOwners)}`);
const mine = u.repos.find((r) => r.name.toLowerCase() === `${other}/maple-factory`);
if (mine?.source !== "github") throw new Error(`${other}/maple-factory: ${JSON.stringify(mine)}`);
if (owned(u.repos, stranger).length) throw new Error(`the stranger's repos came in: ${names(u.repos)}`);
await reposAfter(member, m0, (m) => owned(m.repos, other).length);
step(`approving ${other} (once, without @ or the factory's own account) brings ${owned(u.repos, other).join(", ")} in as GitHub App repos, for everyone`);

const fresh = await connect("mona");
if (JSON.stringify(fresh.last("snapshot").repoOwners) !== JSON.stringify([other])) throw new Error(`member's snapshot: ${JSON.stringify(fresh.last("snapshot").repoOwners)}`);
step(`a fresh snapshot has repoOwners ${JSON.stringify([other])}`);

// The fake numbers installations from 1000 in --installed order, so the stranger's is 1002.
const { log } = await (await fetch(`${gh}/_log`)).json();
const minted = log.filter((e) => /^\/app\/installations\/\d+\/access_tokens$/.test(e.path)).map((e) => Number(e.path.split("/")[3]));
if (minted.includes(1002)) throw new Error(`a token was made for installation 1002 (${stranger}): ${minted}`);
step(`no token was ever made for ${stranger}'s installation (tokens only for ${[...new Set(minted)].join(", ")})`);

n = admin.seen.length;
admin.send({ type: "repos.owners.set", owners: [] });
u = await reposAfter(admin, n, (m) => !owned(m.repos, other).length && m.repoOwners?.length === 0 && owned(m.repos, org).length);
step(`removing ${other} takes its repos out again: ${names(u.repos).join(", ")}`);

for (const c of [admin, member, fresh]) c.close();
process.exit(0);
