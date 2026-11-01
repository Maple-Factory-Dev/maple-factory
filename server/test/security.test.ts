// The fixes from the security audit (SECURITY-AUDIT.md), each against the module it lives in, with
// fakes for D1, R2 and the org hub: runner tokens compared in constant time, uploads cut off at their
// limit however they're sent, the HTML pages' headers, intake reply addresses, and /releases/ not
// serving the bucket's attachments.
import { test } from "node:test";
import assert from "node:assert/strict";
import type { Env } from "../src/env.ts";
import { html, PAGE_HEADERS, readCapped, sameText, sha256 } from "../src/util.ts";
import { authenticateRunner } from "../src/machines.ts";
import { MAX_ATTACHMENT, upload, uploadProof } from "../src/attachments.ts";
import { MAX_ICON, upload as uploadIcon } from "../src/icon.ts";
import { intakeApi } from "../src/intake-routes.ts";
import { release } from "../src/releases.ts";

const MB = 1024 * 1024;
const admin = { login: "ana", name: null, avatarUrl: null, role: "admin", teams: [] };

/** A body of `total` bytes in 1 MB chunks, sent without a content-length, counting what was read. */
function chunked(total: number) {
  const pulled = { bytes: 0 };
  let left = total;
  const body = new ReadableStream<Uint8Array>({
    pull(c) {
      if (left <= 0) return c.close();
      const n = Math.min(MB, left);
      left -= n;
      pulled.bytes += n;
      c.enqueue(new Uint8Array(n).fill(0x41));
    },
  });
  return { body, pulled };
}

const post = (url: string, body: BodyInit, headers: Record<string, string> = {}, method = "POST") =>
  new Request(url, { method, body, headers, duplex: "half" } as RequestInit);

/** D1 with one machine, `m1`, whose token is `token`. */
async function machineDb(token: string) {
  const hash = await sha256(token);
  return {
    prepare: () => ({ bind: () => ({ first: async () => ({ token_hash: hash }), run: async () => ({}) }) }),
  } as unknown as D1Database;
}

test("sameText compares every character, wherever the first difference is", () => {
  assert.equal(sameText("mfr_abc", "mfr_abc"), true);
  assert.equal(sameText("mfr_abc", "mfr_abd"), false);
  assert.equal(sameText("mfr_abc", "mfr_ab"), false);
  // Count the characters looked at: a mismatch in the first place costs as much as one in the last.
  const reads = (a: string, b: string) => {
    let n = 0;
    const counted = (s: string) => ({ length: s.length, charCodeAt: (i: number) => (n++, s.charCodeAt(i)) }) as unknown as string;
    sameText(counted(a), counted(b));
    return n;
  };
  assert.equal(reads("x".repeat(64), "y" + "x".repeat(63)), reads("x".repeat(64), "x".repeat(63) + "y"));
  assert.equal(reads("x".repeat(64), "y" + "x".repeat(63)), 128);
});

test("runner tokens: the right one gets in, a wrong one doesn't, compared without ===", async () => {
  const env = { DB: await machineDb("mfr_right") } as unknown as Env;
  const as = (token: string) => new Request("https://f.test/runner/connect?runner=m1", { headers: { authorization: `Bearer ${token}` } });
  assert.equal(await authenticateRunner(env, "m1", as("mfr_right")), true);
  assert.equal(await authenticateRunner(env, "m1", as("mfr_wrong")), false);
  assert.equal(await authenticateRunner(env, "m1", new Request("https://f.test/")), false);
  const source = authenticateRunner.toString();
  assert.match(source, /sameText\(/);
  assert.doesNotMatch(source, /token_hash ===/);
});

test("readCapped stops reading at the limit when there's no content-length", async () => {
  const { body, pulled } = chunked(40 * MB);
  assert.equal(await readCapped(post("https://f.test/", body), 5 * MB), null);
  assert.ok(pulled.bytes <= 7 * MB, `read ${pulled.bytes / MB} MB of 40`);
  const small = await readCapped(post("https://f.test/", "hello"), 5 * MB);
  assert.equal(new TextDecoder().decode(small!), "hello");
  assert.equal(await readCapped(post("https://f.test/", "x", { "content-length": String(6 * MB) }), 5 * MB), null);
});

test("an oversized attachment without content-length gets 413, without reading it all", async () => {
  const { body, pulled } = chunked(MAX_ATTACHMENT + 20 * MB);
  const res = await upload(post("https://f.test/api/attachments?name=big.png", body, { "content-type": "image/png" }), {} as Env, admin);
  assert.equal(res.status, 413);
  assert.ok(pulled.bytes <= MAX_ATTACHMENT + 2 * MB, `read ${pulled.bytes / MB} MB`);
});

test("a proof without content-length is refused (411), without reading it", async () => {
  const { body, pulled } = chunked(60 * MB);
  const env = { DB: await machineDb("mfr_right") } as unknown as Env;
  const res = await uploadProof(post("https://f.test/runner/proof/MF-1?runner=m1&name=a.mp4", body, { authorization: "Bearer mfr_right" }, "PUT"), env, "MF-1");
  assert.equal(res.status, 411);
  assert.ok(pulled.bytes <= 2 * MB, `read ${pulled.bytes / MB} MB`);
});

test("a proof whose content-length is over 95 MB gets 413, without reading it", async () => {
  const { body, pulled } = chunked(60 * MB);
  const env = { DB: await machineDb("mfr_right") } as unknown as Env;
  const headers = { authorization: "Bearer mfr_right", "content-length": String(96 * MB) };
  const res = await uploadProof(post("https://f.test/runner/proof/MF-1?runner=m1&name=a.mp4", body, headers, "PUT"), env, "MF-1");
  assert.equal(res.status, 413);
  assert.ok(pulled.bytes <= 2 * MB, `read ${pulled.bytes / MB} MB`);
});

test("an image proof over 20 MB gets 413 after reading only its first bytes", async () => {
  let left = 21 * MB;
  const pulled = { bytes: 0 };
  const body = new ReadableStream<Uint8Array>({
    pull(c) {
      if (left <= 0) return c.close();
      const chunk = new Uint8Array(MB);
      if (!pulled.bytes) chunk.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      left -= MB;
      pulled.bytes += MB;
      c.enqueue(chunk);
    },
  });
  const env = { DB: await machineDb("mfr_right") } as unknown as Env;
  const headers = { authorization: "Bearer mfr_right", "content-length": String(21 * MB) };
  const res = await uploadProof(post("https://f.test/runner/proof/MF-1?runner=m1&name=a.png", body, headers, "PUT"), env, "MF-1");
  assert.equal(res.status, 413);
  assert.match(await res.text(), /20 MB/);
  assert.ok(pulled.bytes <= 3 * MB, `read ${pulled.bytes / MB} MB`);
});

test("an oversized icon without content-length gets 413, without reading it all", async () => {
  const { body, pulled } = chunked(30 * MB);
  const res = await uploadIcon(post("https://f.test/api/icon", body, {}, "PUT"), {} as Env, admin);
  assert.equal(res.status, 413);
  assert.ok(pulled.bytes <= MAX_ICON + 2 * MB, `read ${pulled.bytes / MB} MB`);
});

test("HTML pages can't be framed, sniffed or leak a referrer", () => {
  const res = html("<!doctype html><p>hi</p>");
  assert.equal(res.headers.get("content-type"), "text/html; charset=utf-8");
  assert.match(res.headers.get("content-security-policy") ?? "", /frame-ancestors 'none'/);
  assert.equal(res.headers.get("x-frame-options"), "DENY");
  assert.equal(res.headers.get("x-content-type-options"), "nosniff");
  assert.equal(res.headers.get("referrer-policy"), "same-origin");
  assert.equal(PAGE_HEADERS["x-frame-options"], "DENY");
});

/** An env whose org hub records what intake was asked to make. */
function intakeEnv(extra: Partial<Env> = {}) {
  const made: unknown[] = [];
  const hub = { fetch: async (_url: string, init: RequestInit) => (made.push(JSON.parse(String(init.body))), Response.json({ id: "REQ-1" })) };
  const env = { INTAKE_KEY: "mfi_key", ORG: { idFromName: () => "org", get: () => hub }, ...extra } as unknown as Env;
  return { env, made };
}
const intake = (env: Env, body: object) =>
  intakeApi(post("https://f.test/api/intake", JSON.stringify(body), { authorization: "Bearer mfi_key", "content-type": "application/json" }), env, "/api/intake", null);

test("intake: a replyUrl on a host that isn't allowed is refused", async () => {
  const { env, made } = intakeEnv();
  for (const replyUrl of ["https://evil.example/hook", "https://169.254.169.254/", "https://hooks.slack.com.evil.example/x", "http://hooks.slack.com/x"]) {
    const res = await intake(env, { title: "x", replyUrl });
    assert.equal(res?.status, 400, replyUrl);
  }
  assert.equal(made.length, 0);
});

test("intake: Slack's hooks, and hosts in INTAKE_REPLY_HOSTS, are allowed", async () => {
  const { env, made } = intakeEnv({ INTAKE_REPLY_HOSTS: "support.example.com, hooks.zapier.com" });
  for (const replyUrl of ["https://hooks.slack.com/services/T/B/x", "https://support.example.com/maple", "https://HOOKS.zapier.com/a"]) {
    const res = await intake(env, { title: "x", replyUrl });
    assert.equal(res?.status, 200, replyUrl);
  }
  assert.equal(made.length, 3);
  const none = await intake(env, { title: "no reply address" });
  assert.equal(none?.status, 200);
});

test("/releases/ serves release files from the bucket, never attachments or the icon", async () => {
  const objects: Record<string, string> = {
    "maple-runner/latest.json": "{}",
    "attachments/0b1e4d3a-1111-4222-8333-444455556666/x.html": "<script>alert(1)</script>",
    "icon/0b1e4d3a-1111-4222-8333-444455556666": "png",
  };
  const RELEASES = {
    get: async (key: string) => (key in objects ? { body: objects[key], httpMetadata: { contentType: key.endsWith(".html") ? "text/html" : "application/json" }, httpEtag: '"e"' } : null),
  };
  const env = { RELEASES, RELEASE_FEED: "off" } as unknown as Env;
  const ok = await release(env, "maple-runner/latest.json");
  assert.equal(ok?.status, 200);
  assert.equal(ok?.headers.get("x-content-type-options"), "nosniff");
  assert.equal(await release(env, "attachments/0b1e4d3a-1111-4222-8333-444455556666/x.html"), null);
  assert.equal(await release(env, "icon/0b1e4d3a-1111-4222-8333-444455556666"), null);
});
