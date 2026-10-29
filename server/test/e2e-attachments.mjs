// Attachments (src/attachments.ts): files pasted or dropped into briefs and Scratchpad notes.
//   node server/test/e2e-attachments.mjs http://localhost:8788 [the same factory, not signed in]
// The second URL is the same local state served as somewhere other than localhost, so DEV_LOGIN doesn't
// sign everyone in there and anonymous requests can be refused, e.g. from server/:
//   npx wrangler dev --port 8798 --local-upstream factory.test --inspector-port 9330
// Without it, the anonymous checks are skipped. Checks: a member's upload round-trips byte for byte, a
// runner fetches it with its own token, and anonymous requests, wrong tokens, oversize files and
// names with folders or '..' are refused.

import { randomBytes } from "node:crypto";

const [base = "http://localhost:8788", outside] = process.argv.slice(2);
let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const member = { authorization: `Bearer ${token}` };
const upload = (name, body, headers = member, to = base) =>
  fetch(`${to}/api/attachments?name=${encodeURIComponent(name)}`, { method: "POST", headers: { "content-type": "image/png", ...headers }, body });

// A member uploads a screenshot.
const bytes = randomBytes(300_000);
const res = await upload("Screen Shot 2026-10-28 at 10.00.00 AM.png", bytes);
const att = await res.json();
check(res.status === 201, `a member's upload is stored (${res.status})`);
check(/^\/attachments\/[0-9a-f-]{36}\/Screen-Shot-2026-10-28-at-10.00.00-AM\.png$/.test(att.path), `its path names a cleaned-up file (${att.path})`);
check(att.size === bytes.length && att.mime === "image/png" && att.name === att.path.split("/").pop(), "it says its size, type and name");

const got = await fetch(`${base}${att.path}`, { headers: member });
const back = Buffer.from(await got.arrayBuffer());
check(got.status === 200 && back.equals(bytes), `a member gets it back byte for byte (${got.status}, ${back.length} bytes)`);
check(got.headers.get("content-type") === "image/png" && /^inline/.test(got.headers.get("content-disposition") ?? ""), "an image is shown, not downloaded");
check((got.headers.get("content-security-policy") ?? "").includes("sandbox"), "files are sandboxed");

const html = await (await upload("page.html", "<script>alert(1)</script>", { ...member, "content-type": "text/html" })).json();
const page = await fetch(`${base}${html.path}`, { headers: member });
check(/^attachment/.test(page.headers.get("content-disposition") ?? ""), "an HTML file is a download, not a page");

// A runner, with its own token.
const { code } = await (await fetch(`${base}/api/machines/enroll`, { method: "POST", headers: member })).json();
const runnerId = `att-${Date.now().toString(36)}`;
const enrolled = await (await fetch(`${base}/runner/enroll`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code, runnerId }) })).json();
const runnerPath = `${base}/runner${att.path}?runner=${runnerId}`;
const asRunner = await fetch(runnerPath, { headers: { authorization: `Bearer ${enrolled.token}` } });
check(asRunner.status === 200 && Buffer.from(await asRunner.arrayBuffer()).equals(bytes), `the runner gets it with its token (${asRunner.status})`);
const wrong = await fetch(runnerPath, { headers: { authorization: "Bearer mfr_wrong" } });
check(wrong.status === 401, `a wrong runner token is refused (${wrong.status})`);
const none = await fetch(runnerPath);
check(none.status === 401, `no runner token is refused (${none.status})`);
const member404 = await fetch(`${base}/runner${att.path}?runner=${runnerId}`, { headers: member });
check(member404.status === 401, `a member's token isn't a runner's (${member404.status})`);

// Names and sizes.
for (const name of ["../../etc/passwd", "..", "a/b.png", "a\\b.png", "x/../y.png", ""]) {
  const r = await upload(name, "x");
  check(r.status === 400, `the name ${JSON.stringify(name)} is refused (${r.status})`);
}
const dotted = await (await upload("notes.", "trailing")).json();
check(dotted.name === "notes", `a trailing dot is dropped from the stored name (${dotted.name})`);
const dottedRunner = await fetch(`${base}/runner${dotted.path}?runner=${runnerId}`, { headers: { authorization: `Bearer ${enrolled.token}` } });
check(dottedRunner.status === 200, `the runner finds it by the name its link gives (${dottedRunner.status})`);
const traversal = await fetch(`${base}/attachments/${att.path.split("/")[2]}/..%2F..%2Fsecret`, { headers: member });
check(traversal.status === 400, `'..' in a fetched path is refused (${traversal.status})`);
const big = await upload("big.bin", Buffer.alloc(25 * 1024 * 1024 + 1));
check(big.status === 413, `a file over 25 MB is refused (${big.status})`);
const empty = await upload("empty.png", Buffer.alloc(0));
check(empty.status === 400, `an empty file is refused (${empty.status})`);
const missing = await fetch(`${base}/attachments/00000000-0000-4000-8000-000000000000/nope.png`, { headers: member });
check(missing.status === 404, `an attachment that isn't there is 404 (${missing.status})`);

// Anonymous, where DEV_LOGIN doesn't sign everyone in.
if (outside) {
  const anonGet = await fetch(`${outside}${att.path}`);
  check(anonGet.status === 401, `anonymous fetches are refused (${anonGet.status})`);
  const anonPost = await upload("anon.png", "x", {}, outside);
  check(anonPost.status === 401, `anonymous uploads are refused (${anonPost.status})`);
  const badBearer = await fetch(`${outside}${att.path}`, { headers: { authorization: "Bearer mft_wrong" } });
  check(badBearer.status === 401, `a wrong member token is refused (${badBearer.status})`);
  const there = await fetch(`${outside}${att.path}`, { headers: member });
  check(there.status === 200, `a member's token works there (${there.status})`);
} else console.log("skip anonymous checks (no second URL)");

console.log(failures ? `\n${failures} failed` : "\nall passed");
process.exit(failures ? 1 : 0);
