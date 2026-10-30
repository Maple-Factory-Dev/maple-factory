// /setup against the fake GitHub: a fresh factory creates its GitHub App from the manifest and keeps
// the credentials in D1, and refuses an app some other account owns.
//   node server/test/e2e-setup.mjs http://localhost:8788 [org] [personal]
// The server needs GITHUB_ORG=<org> (default acme), GITHUB_API_URL pointing at test/fake-github.mjs,
// a fresh local D1 (no settings rows), and no GITHUB_CLIENT_SECRET. With `personal`, <org> is a
// personal account (run the fake with --user <org>): the app is made on that account, without members.

const [base = "http://localhost:8788", org = "acme", mode] = process.argv.slice(2);
const personal = mode === "personal";
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };
const get = (path, cookie) => fetch(`${base}${path}`, { redirect: "manual", headers: cookie ? { cookie } : {} });

const start = await get("/setup");
const html = await start.text();
const cookie = (start.headers.get("set-cookie") ?? "").split(";")[0];
const action = html.match(/action="([^"]+)"/)?.[1]?.replace(/&amp;/g, "&") ?? "";
const state = new URL(action || "https://x/").searchParams.get("state");
const manifest = JSON.parse((html.match(/name="manifest" value="([^"]+)"/)?.[1] ?? "{}").replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&"));
check(/frame-ancestors 'none'/.test(start.headers.get("content-security-policy") ?? "") && start.headers.get("x-frame-options") === "DENY", "the page can't be framed (clickjacking)");
check(html.match(/<form /g)?.length === 1, "one form: GitHub said what kind of account it is");
check(personal ? action.startsWith("https://github.com/settings/apps/new?state=") : action.startsWith(`https://github.com/organizations/${org}/settings/apps/new?state=`),
  `the form posts to the ${personal ? "account's" : "org's"} new-app page`);
check(Boolean(state) && cookie.includes(state), "the state is also in a cookie");
check(manifest.redirect_url === `${base}/setup/github` && manifest.callback_urls?.[0] === `${base}/auth/callback`, "the manifest comes back here");
check(personal ? !("members" in (manifest.default_permissions ?? {})) : manifest.default_permissions?.members === "read",
  personal ? "the app doesn't ask for org members" : "the app may read org members");

const stranger = await get(`/setup/github?code=app-someone-else&state=${encodeURIComponent(state)}`, cookie);
check(stranger.status === 403, `an app owned by another account is refused (${stranger.status})`);
const forged = await get(`/setup/github?code=app-${org}&state=forged`, cookie);
check(forged.status === 400, `a state that isn't ours is refused (${forged.status})`);

const made = await get(`/setup/github?code=app-${org}&state=${encodeURIComponent(state)}`, cookie);
check(made.status === 302 && made.headers.get("location") === `https://github.com/apps/maple-factory-${org}/installations/new`, `then GitHub installs it (${made.status} ${made.headers.get("location")})`);

const login = await get("/auth/login");
const to = new URL(login.headers.get("location") ?? "https://x/");
check(login.status === 302 && to.host === "github.com" && to.searchParams.get("client_id") === "Iv23fakeclient", "sign-in now uses the new app");
check((await (await get("/setup")).text()).includes("This factory is set up"), "/setup says it's done");
const settings = personal ? `https://github.com/settings/apps/maple-factory-${org}` : `https://github.com/organizations/${org}/settings/apps/maple-factory-${org}`;
check((await (await get("/setup/done")).text()).includes(settings), "/setup/done links to the app's settings for device flow");
check((await (await get("/setup")).text()).includes(personal ? `<b>${org}</b> signs in` : `members of <b>${org}</b> sign in`), "/setup says who signs in");
const again = await get(`/setup/github?code=app-${org}&state=${encodeURIComponent(state)}`, cookie);
check(again.status === 200 && !(again.headers.get("location")), "a second setup doesn't replace the app");

process.exit(failures ? 1 : 0);
